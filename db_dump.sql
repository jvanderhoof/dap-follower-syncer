--
-- PostgreSQL database dump
--

-- Dumped from database version 14.2 (Debian 14.2-1.pgdg110+1)
-- Dumped by pg_dump version 14.1

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pglogical; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA pglogical;


ALTER SCHEMA pglogical OWNER TO postgres;

--
-- Name: hstore; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;


--
-- Name: EXTENSION hstore; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION hstore IS 'data type for storing sets of (key, value) pairs';


--
-- Name: pglogical; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pglogical WITH SCHEMA pglogical;


--
-- Name: EXTENSION pglogical; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pglogical IS 'PostgreSQL Logical Replication';


--
-- Name: policy_log_kind; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.policy_log_kind AS ENUM (
    'roles',
    'role_memberships',
    'resources',
    'permissions',
    'annotations'
);


ALTER TYPE public.policy_log_kind OWNER TO postgres;

--
-- Name: policy_log_op; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.policy_log_op AS ENUM (
    'INSERT',
    'DELETE',
    'UPDATE'
);


ALTER TYPE public.policy_log_op OWNER TO postgres;

--
-- Name: policy_log_record; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.policy_log_record AS (
	policy_id text,
	version integer,
	operation public.policy_log_op,
	kind public.policy_log_kind,
	subject public.hstore
);


ALTER TYPE public.policy_log_record OWNER TO postgres;

--
-- Name: role_graph_edge; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.role_graph_edge AS (
	parent text,
	child text
);


ALTER TYPE public.role_graph_edge OWNER TO postgres;

--
-- Name: account(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.account(id text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT CASE 
       WHEN split_part($1, ':', 1) = '' THEN NULL 
      ELSE split_part($1, ':', 1)
    END
    $_$;


ALTER FUNCTION public.account(id text) OWNER TO postgres;

--
-- Name: kind(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.kind(id text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT CASE 
       WHEN split_part($1, ':', 2) = '' THEN NULL 
      ELSE split_part($1, ':', 2)
    END
    $_$;


ALTER FUNCTION public.kind(id text) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: resources; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.resources (
    resource_id text NOT NULL,
    owner_id text NOT NULL,
    created_at timestamp without time zone DEFAULT transaction_timestamp() NOT NULL,
    policy_id text,
    "timestamp" timestamp without time zone,
    CONSTRAINT has_account CHECK ((public.account(resource_id) IS NOT NULL)),
    CONSTRAINT has_kind CHECK ((public.kind(resource_id) IS NOT NULL)),
    CONSTRAINT verify_policy_kind CHECK ((public.kind(policy_id) = 'policy'::text))
);


ALTER TABLE public.resources OWNER TO postgres;

--
-- Name: account(public.resources); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.account(record public.resources) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
        SELECT account(record.resource_id)
        $$;


ALTER FUNCTION public.account(record public.resources) OWNER TO postgres;

--
-- Name: roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.roles (
    role_id text NOT NULL,
    created_at timestamp without time zone DEFAULT transaction_timestamp() NOT NULL,
    policy_id text,
    CONSTRAINT has_account CHECK ((public.account(role_id) IS NOT NULL)),
    CONSTRAINT has_kind CHECK ((public.kind(role_id) IS NOT NULL)),
    CONSTRAINT verify_policy_kind CHECK ((public.kind(policy_id) = 'policy'::text))
);


ALTER TABLE public.roles OWNER TO postgres;

--
-- Name: account(public.roles); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.account(record public.roles) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
        SELECT account(record.role_id)
        $$;


ALTER FUNCTION public.account(record public.roles) OWNER TO postgres;

--
-- Name: all_roles(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.all_roles(role_id text) RETURNS TABLE(role_id text, admin_option boolean)
    LANGUAGE sql STABLE STRICT ROWS 2376
    AS $_$
          WITH RECURSIVE m(role_id, admin_option) AS (
            SELECT $1, 't'::boolean
              UNION
            SELECT ms.role_id, ms.admin_option FROM role_memberships ms, m
              WHERE member_id = m.role_id
          ) SELECT role_id, bool_or(admin_option) FROM m GROUP BY role_id
        $_$;


ALTER FUNCTION public.all_roles(role_id text) OWNER TO postgres;

--
-- Name: annotation_update_textsearch(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.annotation_update_textsearch() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
        BEGIN
          IF TG_OP IN ('INSERT', 'UPDATE') THEN
          UPDATE resources_textsearch rts
            SET textsearch = (
              SELECT r.tsvector FROM resources r
              WHERE r.resource_id = rts.resource_id
            ) WHERE resource_id = NEW.resource_id;
          END IF;
          
          IF TG_OP IN ('UPDATE', 'DELETE') THEN
            BEGIN
              UPDATE resources_textsearch rts
              SET textsearch = (
                SELECT r.tsvector FROM resources r
                WHERE r.resource_id = rts.resource_id
              ) WHERE resource_id = OLD.resource_id;
            EXCEPTION WHEN foreign_key_violation THEN
              /*
              It's possible when an annotation is deleted that the entire resource
              has been deleted. When this is the case, attempting to update the
              search text will raise a foreign key violation on the missing
              resource_id. 
              */
              RAISE WARNING 'Cannot update search text for % because it no longer exists', OLD.resource_id;
              RETURN NULL;
            END;
          END IF;

          RETURN NULL;
        END
        $$;


ALTER FUNCTION public.annotation_update_textsearch() OWNER TO postgres;

--
-- Name: policy_versions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.policy_versions (
    resource_id text NOT NULL,
    role_id text NOT NULL,
    version integer NOT NULL,
    created_at timestamp with time zone DEFAULT transaction_timestamp() NOT NULL,
    policy_text text NOT NULL,
    policy_sha256 text NOT NULL,
    finished_at timestamp with time zone,
    client_ip text,
    CONSTRAINT created_before_finish CHECK ((created_at <= finished_at))
);


ALTER TABLE public.policy_versions OWNER TO postgres;

--
-- Name: current_policy_version(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.current_policy_version() RETURNS SETOF public.policy_versions
    LANGUAGE sql STABLE
    SET search_path TO '$user', 'public'
    AS $$
          SELECT * FROM policy_versions WHERE finished_at IS NULL $$;


ALTER FUNCTION public.current_policy_version() OWNER TO postgres;

--
-- Name: delete_role_membership_of_owner(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_role_membership_of_owner(role_id text, owner_id text) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
      DECLARE
        row_count int;
      BEGIN
        DELETE FROM role_memberships rm
          WHERE rm.role_id = $1 AND
            member_id = $2 AND
            ownership = true;
        GET DIAGNOSTICS row_count = ROW_COUNT;
        RETURN row_count;
      END
      $_$;


ALTER FUNCTION public.delete_role_membership_of_owner(role_id text, owner_id text) OWNER TO postgres;

--
-- Name: delete_role_membership_of_owner_trigger(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_role_membership_of_owner_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
        PERFORM delete_role_membership_of_owner(OLD.resource_id, OLD.owner_id);

        RETURN OLD;
      END
      $$;


ALTER FUNCTION public.delete_role_membership_of_owner_trigger() OWNER TO postgres;

--
-- Name: grant_role_membership_to_owner(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.grant_role_membership_to_owner(role_id text, owner_id text) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
      DECLARE
        rolsource_role roles%rowtype;
        existing_grant role_memberships%rowtype;
      BEGIN
        SELECT * INTO rolsource_role FROM roles WHERE roles.role_id = $1;
        IF FOUND THEN
          SELECT * INTO existing_grant FROM role_memberships rm WHERE rm.role_id = $1 AND rm.member_id = $2 AND rm.admin_option = true AND rm.ownership = true;
          IF NOT FOUND THEN
            INSERT INTO role_memberships ( role_id, member_id, admin_option, ownership )
              VALUES ( $1, $2, true, true );
            RETURN 1;
          END IF;
        END IF;
        RETURN 0;
      END
      $_$;


ALTER FUNCTION public.grant_role_membership_to_owner(role_id text, owner_id text) OWNER TO postgres;

--
-- Name: grant_role_membership_to_owner_trigger(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.grant_role_membership_to_owner_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
        PERFORM grant_role_membership_to_owner(NEW.resource_id, NEW.owner_id);
        RETURN NEW;
      END
      $$;


ALTER FUNCTION public.grant_role_membership_to_owner_trigger() OWNER TO postgres;

--
-- Name: identifier(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.identifier(id text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT SUBSTRING($1 from '[^:]+:[^:]+:(.*)');
    $_$;


ALTER FUNCTION public.identifier(id text) OWNER TO postgres;

--
-- Name: identifier(public.resources); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.identifier(record public.resources) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
      SELECT identifier(record.resource_id)
      $$;


ALTER FUNCTION public.identifier(record public.resources) OWNER TO postgres;

--
-- Name: identifier(public.roles); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.identifier(record public.roles) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
      SELECT identifier(record.role_id)
      $$;


ALTER FUNCTION public.identifier(record public.roles) OWNER TO postgres;

--
-- Name: is_resource_visible(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_resource_visible(resource_id text, role_id text) RETURNS boolean
    LANGUAGE sql STABLE STRICT
    AS $_$
        WITH RECURSIVE search(role_id) AS (
          -- We expand transitively back from the set of roles that the
          -- resource is visible to instead of relying on all_roles().
          -- This has the advantage of not being sensitive to the size of the
          -- role graph of the argument and hence offers stable performance
          -- even when a powerful role is tested, at the expense of slightly
          -- worse performance of a failed check for a locked-down role.
          -- This way all checks take ~ 1 ms regardless of the role.
          SELECT owner_id FROM resources WHERE resource_id = $1
            UNION
          SELECT role_id FROM permissions WHERE resource_id = $1
            UNION
          SELECT m.member_id
            FROM role_memberships m NATURAL JOIN search s
        )
        SELECT COUNT(*) > 0 FROM (
          SELECT true FROM search
            WHERE role_id = $2
            LIMIT 1 -- early cutoff: abort search if found
        ) AS found
      $_$;


ALTER FUNCTION public.is_resource_visible(resource_id text, role_id text) OWNER TO postgres;

--
-- Name: is_role_allowed_to(text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_role_allowed_to(role_id text, privilege text, resource_id text) RETURNS boolean
    LANGUAGE sql STABLE STRICT
    AS $_$
        WITH 
          all_roles AS (SELECT role_id FROM all_roles($1))
        SELECT COUNT(*) > 0 FROM (
          SELECT 1 FROM all_roles, resources 
          WHERE owner_id = role_id
            AND resources.resource_id = $3
        UNION
          SELECT 1 FROM ( all_roles JOIN permissions USING ( role_id ) ) JOIN resources USING ( resource_id )
          WHERE privilege = $2
            AND resources.resource_id = $3
        ) AS _
      $_$;


ALTER FUNCTION public.is_role_allowed_to(role_id text, privilege text, resource_id text) OWNER TO postgres;

--
-- Name: is_role_ancestor_of(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_role_ancestor_of(role_id text, other_id text) RETURNS boolean
    LANGUAGE sql STABLE STRICT
    AS $_$
        SELECT COUNT(*) > 0 FROM (
          WITH RECURSIVE m(id) AS (
            SELECT $2
            UNION ALL
            SELECT role_id FROM role_memberships rm, m WHERE member_id = id
          )
          SELECT true FROM m WHERE id = $1 LIMIT 1
        )_
      $_$;


ALTER FUNCTION public.is_role_ancestor_of(role_id text, other_id text) OWNER TO postgres;

--
-- Name: kind(public.resources); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.kind(record public.resources) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
        SELECT kind(record.resource_id)
        $$;


ALTER FUNCTION public.kind(record public.resources) OWNER TO postgres;

--
-- Name: kind(public.roles); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.kind(record public.roles) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
        SELECT kind(record.role_id)
        $$;


ALTER FUNCTION public.kind(record public.roles) OWNER TO postgres;

--
-- Name: policy_log_annotations(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_log_annotations() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
          DECLARE
            subject annotations;
            current policy_versions;
            skip boolean;
          BEGIN
            IF (TG_OP = 'DELETE') THEN
              subject := OLD;
            ELSE
              subject := NEW;
            END IF;

            BEGIN
                skip := current_setting('conjur.skip_insert_policy_log_trigger');
            EXCEPTION WHEN OTHERS THEN
                skip := false;
            END;

            IF skip THEN
              RETURN subject;
            END IF;

            current = current_policy_version();
            IF current.resource_id = subject.policy_id THEN
              INSERT INTO policy_log(
                policy_id, version,
                operation, kind,
                subject)
              SELECT
                (policy_log_record(
                    'annotations',
                    ARRAY['resource_id','name'],
                    hstore(subject),
                    current.resource_id,
                    current.version,
                    TG_OP
                  )).*;
            ELSE
              RAISE WARNING 'modifying data outside of policy load: %', subject.policy_id;
            END IF;
            RETURN subject;
          END;
        $$;


ALTER FUNCTION public.policy_log_annotations() OWNER TO postgres;

--
-- Name: policy_log_permissions(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_log_permissions() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
          DECLARE
            subject permissions;
            current policy_versions;
            skip boolean;
          BEGIN
            IF (TG_OP = 'DELETE') THEN
              subject := OLD;
            ELSE
              subject := NEW;
            END IF;

            BEGIN
                skip := current_setting('conjur.skip_insert_policy_log_trigger');
            EXCEPTION WHEN OTHERS THEN
                skip := false;
            END;

            IF skip THEN
              RETURN subject;
            END IF;

            current = current_policy_version();
            IF current.resource_id = subject.policy_id THEN
              INSERT INTO policy_log(
                policy_id, version,
                operation, kind,
                subject)
              SELECT
                (policy_log_record(
                    'permissions',
                    ARRAY['privilege','resource_id','role_id'],
                    hstore(subject),
                    current.resource_id,
                    current.version,
                    TG_OP
                  )).*;
            ELSE
              RAISE WARNING 'modifying data outside of policy load: %', subject.policy_id;
            END IF;
            RETURN subject;
          END;
        $$;


ALTER FUNCTION public.policy_log_permissions() OWNER TO postgres;

--
-- Name: policy_log_record(text, text[], public.hstore, text, integer, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_log_record(table_name text, pkey_cols text[], subject public.hstore, policy_id text, policy_version integer, operation text) RETURNS public.policy_log_record
    LANGUAGE plpgsql
    AS $$
      BEGIN
        return (
          policy_id,
          policy_version,
          operation::policy_log_op,
          table_name::policy_log_kind,
          slice(subject, pkey_cols)
          );
      END;
      $$;


ALTER FUNCTION public.policy_log_record(table_name text, pkey_cols text[], subject public.hstore, policy_id text, policy_version integer, operation text) OWNER TO postgres;

--
-- Name: policy_log_resources(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_log_resources() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
          DECLARE
            subject resources;
            current policy_versions;
            skip boolean;
          BEGIN
            IF (TG_OP = 'DELETE') THEN
              subject := OLD;
            ELSE
              subject := NEW;
            END IF;

            BEGIN
                skip := current_setting('conjur.skip_insert_policy_log_trigger');
            EXCEPTION WHEN OTHERS THEN
                skip := false;
            END;

            IF skip THEN
              RETURN subject;
            END IF;

            current = current_policy_version();
            IF current.resource_id = subject.policy_id THEN
              INSERT INTO policy_log(
                policy_id, version,
                operation, kind,
                subject)
              SELECT
                (policy_log_record(
                    'resources',
                    ARRAY['resource_id'],
                    hstore(subject),
                    current.resource_id,
                    current.version,
                    TG_OP
                  )).*;
            ELSE
              RAISE WARNING 'modifying data outside of policy load: %', subject.policy_id;
            END IF;
            RETURN subject;
          END;
        $$;


ALTER FUNCTION public.policy_log_resources() OWNER TO postgres;

--
-- Name: policy_log_role_memberships(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_log_role_memberships() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
          DECLARE
            subject role_memberships;
            current policy_versions;
            skip boolean;
          BEGIN
            IF (TG_OP = 'DELETE') THEN
              subject := OLD;
            ELSE
              subject := NEW;
            END IF;

            BEGIN
                skip := current_setting('conjur.skip_insert_policy_log_trigger');
            EXCEPTION WHEN OTHERS THEN
                skip := false;
            END;

            IF skip THEN
              RETURN subject;
            END IF;

            current = current_policy_version();
            IF current.resource_id = subject.policy_id THEN
              INSERT INTO policy_log(
                policy_id, version,
                operation, kind,
                subject)
              SELECT
                (policy_log_record(
                    'role_memberships',
                    ARRAY['role_id','member_id','ownership'],
                    hstore(subject),
                    current.resource_id,
                    current.version,
                    TG_OP
                  )).*;
            ELSE
              RAISE WARNING 'modifying data outside of policy load: %', subject.policy_id;
            END IF;
            RETURN subject;
          END;
        $$;


ALTER FUNCTION public.policy_log_role_memberships() OWNER TO postgres;

--
-- Name: policy_log_roles(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_log_roles() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
          DECLARE
            subject roles;
            current policy_versions;
            skip boolean;
          BEGIN
            IF (TG_OP = 'DELETE') THEN
              subject := OLD;
            ELSE
              subject := NEW;
            END IF;

            BEGIN
                skip := current_setting('conjur.skip_insert_policy_log_trigger');
            EXCEPTION WHEN OTHERS THEN
                skip := false;
            END;

            IF skip THEN
              RETURN subject;
            END IF;

            current = current_policy_version();
            IF current.resource_id = subject.policy_id THEN
              INSERT INTO policy_log(
                policy_id, version,
                operation, kind,
                subject)
              SELECT
                (policy_log_record(
                    'roles',
                    ARRAY['role_id'],
                    hstore(subject),
                    current.resource_id,
                    current.version,
                    TG_OP
                  )).*;
            ELSE
              RAISE WARNING 'modifying data outside of policy load: %', subject.policy_id;
            END IF;
            RETURN subject;
          END;
        $$;


ALTER FUNCTION public.policy_log_roles() OWNER TO postgres;

--
-- Name: policy_versions_finish(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_versions_finish() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          UPDATE policy_versions pv
            SET finished_at = clock_timestamp()
            WHERE finished_at IS NULL;
          RETURN new;
        END;
      $$;


ALTER FUNCTION public.policy_versions_finish() OWNER TO postgres;

--
-- Name: policy_versions_next_version(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.policy_versions_next_version() RETURNS trigger
    LANGUAGE plpgsql STABLE STRICT
    AS $$
        DECLARE
          next_version integer;
        BEGIN
          SELECT coalesce(max(version), 0) + 1 INTO next_version
            FROM policy_versions 
            WHERE resource_id = NEW.resource_id;

          NEW.version = next_version;
          RETURN NEW;
        END
        $$;


ALTER FUNCTION public.policy_versions_next_version() OWNER TO postgres;

--
-- Name: resource_update_textsearch(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.resource_update_textsearch() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
        BEGIN
          IF TG_OP = 'INSERT' THEN
            INSERT INTO resources_textsearch
            VALUES (NEW.resource_id, tsvector(NEW));
          ELSE
            UPDATE resources_textsearch
            SET textsearch = tsvector(NEW)
            WHERE resource_id = NEW.resource_id;
          END IF;

          RETURN NULL;
        END
        $$;


ALTER FUNCTION public.resource_update_textsearch() OWNER TO postgres;

--
-- Name: role_graph(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.role_graph(start_role text) RETURNS SETOF public.role_graph_edge
    LANGUAGE sql STABLE
    AS $$

        WITH RECURSIVE 
        -- Ancestor tree
        up AS (
          (SELECT role_id, member_id FROM role_memberships LIMIT 0)
          UNION ALL
            SELECT start_role, NULL

          UNION

          SELECT rm.role_id, rm.member_id FROM role_memberships rm, up
          WHERE up.role_id = rm.member_id
        ),

        -- Descendent tree
        down AS (
            (SELECT role_id, member_id FROM role_memberships LIMIT 0)
          UNION ALL
            SELECT NULL, start_role

          UNION

          SELECT rm.role_id, rm.member_id FROM role_memberships rm, down
          WHERE down.member_id = rm.role_id
        ),

        total AS (
          SELECT * FROM up
          UNION

          -- add immediate children of the ancestors
          -- (they can be fetched anyway through role_members method)
          SELECT rm.role_id, rm.member_id FROM role_memberships rm, up WHERE rm.role_id = up.role_id

          UNION
          SELECT * FROM down
        )

        SELECT * FROM total WHERE role_id IS NOT NULL AND member_id IS NOT NULL
        UNION
        SELECT role_id, member_id FROM role_memberships WHERE start_role IS NULL

      $$;


ALTER FUNCTION public.role_graph(start_role text) OWNER TO postgres;

--
-- Name: FUNCTION role_graph(start_role text); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.role_graph(start_role text) IS 'if role is not null, returns role_memberships culled to include only the two trees rooted at given role, plus the skin of the up tree; otherwise returns all of role_memberships';


--
-- Name: roles_that_can(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.roles_that_can(permission text, resource_id text) RETURNS SETOF public.roles
    LANGUAGE sql STABLE STRICT ROWS 10
    AS $_$
          WITH RECURSIVE allowed_roles(role_id) AS (
            SELECT role_id FROM permissions
              WHERE privilege = $1
                AND resource_id = $2
            UNION SELECT owner_id FROM resources
                WHERE resources.resource_id = $2
            UNION SELECT member_id AS role_id FROM role_memberships ms NATURAL JOIN allowed_roles
            ) SELECT DISTINCT r.* FROM roles r NATURAL JOIN allowed_roles;
        $_$;


ALTER FUNCTION public.roles_that_can(permission text, resource_id text) OWNER TO postgres;

--
-- Name: secrets_next_version(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.secrets_next_version() RETURNS trigger
    LANGUAGE plpgsql STABLE STRICT
    AS $$
        DECLARE
          next_version integer;
        BEGIN
          SELECT coalesce(max(version), 0) + 1 INTO next_version
            FROM secrets 
            WHERE resource_id = NEW.resource_id;

          NEW.version = next_version;
          RETURN NEW;
        END
        $$;


ALTER FUNCTION public.secrets_next_version() OWNER TO postgres;

--
-- Name: tsvector(public.resources); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.tsvector(resource public.resources) RETURNS tsvector
    LANGUAGE sql
    AS $$
        WITH annotations AS (
          SELECT name, value FROM annotations
          WHERE resource_id = resource.resource_id
        )
        SELECT
        -- id and name are A

        -- Translate chars that are not considered word separators by parser. Note that Conjur v3's /authz
        -- did not include a period here. It has been added for Conjur OSS.
        -- Note: although ids are not english, use english dict so that searching is simpler, if less strict
        setweight(to_tsvector('pg_catalog.english', translate(identifier(resource.resource_id), './-', '   ')), 'A') ||

        setweight(to_tsvector('pg_catalog.english',
          coalesce((SELECT value FROM annotations WHERE name = 'name'), '')
        ), 'A') ||

        -- other annotations are B
        setweight(to_tsvector('pg_catalog.english',
          (SELECT coalesce(string_agg(value, ' :: '), '') FROM annotations WHERE name <> 'name')
        ), 'B') ||

        -- kind is C
        setweight(to_tsvector('pg_catalog.english', kind(resource.resource_id)), 'C')
        $$;


ALTER FUNCTION public.tsvector(resource public.resources) OWNER TO postgres;

--
-- Name: update_role_membership_of_owner_trigger(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_role_membership_of_owner_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
        IF OLD.owner_id != NEW.owner_id THEN
          PERFORM delete_role_membership_of_owner(OLD.resource_id, OLD.owner_id);
          PERFORM grant_role_membership_to_owner(OLD.resource_id, NEW.owner_id);
        END IF;
        RETURN NEW;
      END
      $$;


ALTER FUNCTION public.update_role_membership_of_owner_trigger() OWNER TO postgres;

--
-- Name: visible_resources(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.visible_resources(role_id text) RETURNS SETOF public.resources
    LANGUAGE sql STABLE STRICT
    AS $$
        WITH
          all_roles AS (SELECT * FROM all_roles(role_id)),
          permitted AS (
            SELECT DISTINCT resource_id FROM permissions NATURAL JOIN all_roles
          )
        SELECT *
          FROM resources
          WHERE
            -- resource is visible if there are any permissions or ownerships held on it
            owner_id IN (SELECT role_id FROM all_roles)
            OR resource_id IN (SELECT resource_id FROM permitted)
      $$;


ALTER FUNCTION public.visible_resources(role_id text) OWNER TO postgres;

--
-- Name: annotations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.annotations (
    resource_id text NOT NULL,
    name text NOT NULL,
    value text NOT NULL,
    policy_id text,
    CONSTRAINT verify_policy_kind CHECK ((public.kind(policy_id) = 'policy'::text))
);


ALTER TABLE public.annotations OWNER TO postgres;

--
-- Name: authenticator_configs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.authenticator_configs (
    id integer NOT NULL,
    resource_id text NOT NULL,
    enabled boolean DEFAULT false NOT NULL
);


ALTER TABLE public.authenticator_configs OWNER TO postgres;

--
-- Name: authenticator_configs_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.authenticator_configs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.authenticator_configs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: credentials; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.credentials (
    role_id text NOT NULL,
    client_id text,
    api_key bytea,
    encrypted_hash bytea,
    expiration timestamp without time zone,
    restricted_to cidr[] DEFAULT '{}'::cidr[] NOT NULL
);


ALTER TABLE public.credentials OWNER TO postgres;

--
-- Name: host_factory_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.host_factory_tokens (
    token_sha256 character varying(64) NOT NULL,
    token bytea NOT NULL,
    resource_id text NOT NULL,
    cidr cidr[] DEFAULT '{}'::cidr[] NOT NULL,
    expiration timestamp without time zone
);


ALTER TABLE public.host_factory_tokens OWNER TO postgres;

--
-- Name: permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.permissions (
    privilege text NOT NULL,
    resource_id text NOT NULL,
    role_id text NOT NULL,
    policy_id text,
    CONSTRAINT verify_policy_kind CHECK ((public.kind(policy_id) = 'policy'::text))
);


ALTER TABLE public.permissions OWNER TO postgres;

--
-- Name: policy_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.policy_log (
    policy_id text NOT NULL,
    version integer NOT NULL,
    operation public.policy_log_op NOT NULL,
    kind public.policy_log_kind NOT NULL,
    subject public.hstore NOT NULL,
    at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


ALTER TABLE public.policy_log OWNER TO postgres;

--
-- Name: resources_textsearch; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.resources_textsearch (
    resource_id text NOT NULL,
    textsearch tsvector
);


ALTER TABLE public.resources_textsearch OWNER TO postgres;

--
-- Name: role_memberships; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.role_memberships (
    role_id text NOT NULL,
    member_id text NOT NULL,
    admin_option boolean DEFAULT false NOT NULL,
    ownership boolean DEFAULT false NOT NULL,
    policy_id text,
    CONSTRAINT verify_policy_kind CHECK ((public.kind(policy_id) = 'policy'::text))
);


ALTER TABLE public.role_memberships OWNER TO postgres;

--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.schema_migrations (
    filename text NOT NULL
);


ALTER TABLE public.schema_migrations OWNER TO postgres;

--
-- Name: secrets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.secrets (
    resource_id text NOT NULL,
    version integer NOT NULL,
    value bytea NOT NULL,
    expires_at timestamp without time zone,
    "timestamp" timestamp without time zone
);


ALTER TABLE public.secrets OWNER TO postgres;

--
-- Name: slosilo_keystore; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.slosilo_keystore (
    id text NOT NULL,
    key bytea NOT NULL,
    fingerprint text NOT NULL
);


ALTER TABLE public.slosilo_keystore OWNER TO postgres;

--
-- Name: annotations annotations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT annotations_pkey PRIMARY KEY (resource_id, name);


--
-- Name: authenticator_configs authenticator_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.authenticator_configs
    ADD CONSTRAINT authenticator_configs_pkey PRIMARY KEY (id);


--
-- Name: authenticator_configs authenticator_configs_resource_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.authenticator_configs
    ADD CONSTRAINT authenticator_configs_resource_id_key UNIQUE (resource_id);


--
-- Name: credentials credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.credentials
    ADD CONSTRAINT credentials_pkey PRIMARY KEY (role_id);


--
-- Name: host_factory_tokens host_factory_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.host_factory_tokens
    ADD CONSTRAINT host_factory_tokens_pkey PRIMARY KEY (token_sha256);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (resource_id, role_id, privilege);


--
-- Name: policy_versions policy_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_versions
    ADD CONSTRAINT policy_versions_pkey PRIMARY KEY (resource_id, version);


--
-- Name: resources resources_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_pkey PRIMARY KEY (resource_id);


--
-- Name: resources_textsearch resources_textsearch_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.resources_textsearch
    ADD CONSTRAINT resources_textsearch_pkey PRIMARY KEY (resource_id);


--
-- Name: role_memberships role_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_memberships
    ADD CONSTRAINT role_memberships_pkey PRIMARY KEY (role_id, member_id, ownership);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (role_id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (filename);


--
-- Name: secrets secrets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.secrets
    ADD CONSTRAINT secrets_pkey PRIMARY KEY (resource_id, version);


--
-- Name: slosilo_keystore slosilo_keystore_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slosilo_keystore
    ADD CONSTRAINT slosilo_keystore_fingerprint_key UNIQUE (fingerprint);


--
-- Name: slosilo_keystore slosilo_keystore_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slosilo_keystore
    ADD CONSTRAINT slosilo_keystore_pkey PRIMARY KEY (id);


--
-- Name: annotations_name_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX annotations_name_index ON public.annotations USING btree (name);


--
-- Name: policy_log_policy_id_version_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX policy_log_policy_id_version_index ON public.policy_log USING btree (policy_id, version);


--
-- Name: resources_account_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX resources_account_idx ON public.resources USING btree (public.account(resource_id));


--
-- Name: resources_account_kind_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX resources_account_kind_idx ON public.resources USING btree (public.account(resource_id), public.kind(resource_id));


--
-- Name: resources_kind_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX resources_kind_idx ON public.resources USING btree (public.kind(resource_id));


--
-- Name: resources_ts_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX resources_ts_index ON public.resources_textsearch USING gist (textsearch);


--
-- Name: role_memberships_member; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX role_memberships_member ON public.role_memberships USING btree (member_id);


--
-- Name: roles_account_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX roles_account_idx ON public.roles USING btree (public.account(role_id));


--
-- Name: roles_account_kind_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX roles_account_kind_idx ON public.roles USING btree (public.account(role_id), public.kind(role_id));


--
-- Name: roles_kind_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX roles_kind_idx ON public.roles USING btree (public.kind(role_id));


--
-- Name: secrets_account_kind_identifier_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX secrets_account_kind_identifier_idx ON public.secrets USING btree (public.account(resource_id), public.kind(resource_id), public.identifier(resource_id) text_pattern_ops);


--
-- Name: secrets_resource_id_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX secrets_resource_id_index ON public.secrets USING btree (resource_id);


--
-- Name: annotations annotation_update_textsearch; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER annotation_update_textsearch AFTER INSERT OR DELETE OR UPDATE ON public.annotations FOR EACH ROW EXECUTE FUNCTION public.annotation_update_textsearch();


--
-- Name: resources delete_role_membership_of_owner; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER delete_role_membership_of_owner BEFORE DELETE ON public.resources FOR EACH ROW EXECUTE FUNCTION public.delete_role_membership_of_owner_trigger();


--
-- Name: policy_versions finish_current; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE CONSTRAINT TRIGGER finish_current AFTER INSERT ON public.policy_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((new.finished_at IS NULL)) EXECUTE FUNCTION public.policy_versions_finish();


--
-- Name: resources grant_role_membership_to_owner; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER grant_role_membership_to_owner BEFORE INSERT ON public.resources FOR EACH ROW EXECUTE FUNCTION public.grant_role_membership_to_owner_trigger();


--
-- Name: policy_versions only_one_current; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER only_one_current BEFORE INSERT ON public.policy_versions FOR EACH ROW EXECUTE FUNCTION public.policy_versions_finish();


--
-- Name: annotations policy_log; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log AFTER INSERT OR UPDATE ON public.annotations FOR EACH ROW WHEN ((new.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_annotations();


--
-- Name: permissions policy_log; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log AFTER INSERT OR UPDATE ON public.permissions FOR EACH ROW WHEN ((new.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_permissions();


--
-- Name: resources policy_log; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log AFTER INSERT OR UPDATE ON public.resources FOR EACH ROW WHEN ((new.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_resources();


--
-- Name: role_memberships policy_log; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log AFTER INSERT OR UPDATE ON public.role_memberships FOR EACH ROW WHEN ((new.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_role_memberships();


--
-- Name: roles policy_log; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log AFTER INSERT OR UPDATE ON public.roles FOR EACH ROW WHEN ((new.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_roles();


--
-- Name: annotations policy_log_d; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log_d AFTER DELETE ON public.annotations FOR EACH ROW WHEN ((old.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_annotations();


--
-- Name: permissions policy_log_d; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log_d AFTER DELETE ON public.permissions FOR EACH ROW WHEN ((old.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_permissions();


--
-- Name: resources policy_log_d; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log_d AFTER DELETE ON public.resources FOR EACH ROW WHEN ((old.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_resources();


--
-- Name: role_memberships policy_log_d; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log_d AFTER DELETE ON public.role_memberships FOR EACH ROW WHEN ((old.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_role_memberships();


--
-- Name: roles policy_log_d; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_log_d AFTER DELETE ON public.roles FOR EACH ROW WHEN ((old.policy_id IS NOT NULL)) EXECUTE FUNCTION public.policy_log_roles();


--
-- Name: policy_versions policy_versions_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_versions_version BEFORE INSERT ON public.policy_versions FOR EACH ROW EXECUTE FUNCTION public.policy_versions_next_version();


--
-- Name: resources resource_update_textsearch; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER resource_update_textsearch AFTER INSERT OR UPDATE ON public.resources FOR EACH ROW EXECUTE FUNCTION public.resource_update_textsearch();


--
-- Name: secrets secrets_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER secrets_version BEFORE INSERT ON public.secrets FOR EACH ROW EXECUTE FUNCTION public.secrets_next_version();


--
-- Name: resources update_role_membership_of_owner; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_role_membership_of_owner BEFORE UPDATE ON public.resources FOR EACH ROW EXECUTE FUNCTION public.update_role_membership_of_owner_trigger();


--
-- Name: annotations annotations_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT annotations_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: annotations annotations_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT annotations_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: authenticator_configs authenticator_configs_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.authenticator_configs
    ADD CONSTRAINT authenticator_configs_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: credentials credentials_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.credentials
    ADD CONSTRAINT credentials_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: host_factory_tokens host_factory_tokens_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.host_factory_tokens
    ADD CONSTRAINT host_factory_tokens_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: permissions permissions_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: permissions permissions_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: permissions permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: policy_log policy_log_policy_id_version_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_log
    ADD CONSTRAINT policy_log_policy_id_version_fkey FOREIGN KEY (policy_id, version) REFERENCES public.policy_versions(resource_id, version) ON DELETE CASCADE;


--
-- Name: policy_versions policy_versions_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_versions
    ADD CONSTRAINT policy_versions_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: policy_versions policy_versions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_versions
    ADD CONSTRAINT policy_versions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: resources resources_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: resources resources_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: resources_textsearch resources_textsearch_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.resources_textsearch
    ADD CONSTRAINT resources_textsearch_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: role_memberships role_memberships_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_memberships
    ADD CONSTRAINT role_memberships_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: role_memberships role_memberships_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_memberships
    ADD CONSTRAINT role_memberships_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: role_memberships role_memberships_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_memberships
    ADD CONSTRAINT role_memberships_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: roles roles_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- Name: secrets secrets_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.secrets
    ADD CONSTRAINT secrets_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resources(resource_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

