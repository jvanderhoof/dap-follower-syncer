# Partial Replication Using Logical Replication and Notifications

## Overview

![Overview](./out/diagrams/overview/overview.png)

- Replicate all data EXCEPT for Variable Values
- Follower monitors Leader's Variables for variables it's been permitted
- Follower replicates changed values

# Steps For Enabling Logical Replication

1. On leader postgresql.conf file, set `wal_level = logical`
    1.A. Log onto Leader PG: `psql -h localhost -U postgres -W postgres`
    1.B. verify by issuing `SHOW wal_level;`.  Result should be:

        ```
        postgres=# show WAL_LEVEL;
        wal_level
        -----------
        logical
        (1 row)
        ```
2. Run setup

    ```sh
    rake partial_replication:setup
    ```

3. On Leader, run: `CREATE PUBLICATION partial_replica_publication FOR TABLE annotations,authenticator_configs,credentials,host_factory_tokens,permissions,policy_log,policy_versions,resources,resources_textsearch,role_memberships,roles,slosilo_keystore;`

4. Log into Follower Postgres: `psql -h localhost -p 5433 -U postgres -W postgres`
   1.  Enable replication:
       ```sql
       CREATE SUBSCRIPTION partial_replica_subscription CONNECTION 'host=pg-leader port=5432 dbname=postgres password=Password123' PUBLICATION partial_replica_publication;
       ```


5. Add Policy and set variable data on the Leader

    ```sh
    rake partial_replication:load_data
    ```

6. Verify Policy in Follower

7. Verify Variables not present in Follower

8. Replicate data

    ```sh
    rake partial_replication:replicate
    ```

9.  Start a listener:

    ```sh
    rake partial_replication:listen
    ```

10. Send a notification:

    ```sh
    rake partial_replication:notify
    ```

## Conjur Enhancements
- Need to be able to get total count to allow for paging
-
