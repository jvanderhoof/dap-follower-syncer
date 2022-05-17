require 'securerandom'

require 'rubygems'
require 'bundler/setup'
require 'conjur/api'

require 'sequel'
require 'pry'

ADMIN_API_KEY = 'kpmdv71x51a521qjwhcy1b5xr2q2gvfbjp3ct9ds23p8mkwy21j6ht5'.freeze
ACCOUNT = 'default'.freeze

module PolicyGenerator
  # Renders ERB given a template and variable hash
  class Render
    def render(template:, args:)
      ERB.new(template, nil, '-').result_with_hash(args)
    end
  end
  module Templates
    class PartialReplicaHost
      def self.template(host:)
        <<~TEMPLATE
          # One or more unique hosts should exist per replica. A host is used to identify
          # a unique follower.
          - !host #{host}

          # Add the above follower to the replica set.
          - !grant
            role: !group
            member: !host #{host}
        TEMPLATE
      end
    end

    class ReplicaSet
      def self.template(replicaset_id:)
        <<~TEMPLATE
          # Sample partial replica template
          # The following policy needs to be created once per replica set
          - !policy
            id: #{replicaset_id}
            body:
              # Webservice to enable replication permissions
              - !webservice

              # Holds the unique identifier for this replication set
              - !variable replica-id

              # All replicated variables for this Replication Set will be added
              # to this group:
              - !group replicated-data

              # Give the role `replicated-data` permission to replicate
              - !permit
                role: !group replicated-data
                privilege: [ replicate ]
                resource: !webservice

              # !!!!
              # Section below is only if we want a host to be able to replicate
              # from it's Replication Sets without using a seed file.
              # !!!!

              # Group to collect follower hosts in this replica set
              - !group

              - !permit
                resource: !variable replica-id
                privileges: [ read, execute ]
                role: !group

              # give replica group the role replicated-data to allow
              # users to mark data as "replicatable" for this follower
              - !grant
                member: !group
                role: !group replicated-data
        TEMPLATE
      end
    end

    # class BasePolicy
    #   def self.template
    #     <<~TEMPLATE
    #     - !policy
    #       id: conjur
    #       body:
    #         #{authenticators.map { |a| "    - !policy #{a}" }.join("/n")}
    #         - !policy
    #           id: members
    #           body:
    #           - !policy leaders
    #           - !policy followers
    #     TEMPLATE
    #   end
    # end

    # class DatabaseConnection
    #   def self.template
    #     <<~TEMPLATE
    #     - !policy
    #       id: database-connection
    #       body:
    #         - &variables
    #           - !variable username
    #           - !variable password
    #           - !variable url
    #           - !variable port
    #           - !variable database-type

    #         - !group consumers
    #         - !group managers

    #         # consumers can read and execute
    #         - !permit
    #           resource: *variables
    #           privileges: [ read, execute ]
    #           role: !group consumers

    #         # managers can update (and read and execute, via role grant)
    #         - !permit
    #           resource: *variables
    #           privileges: [ update ]
    #           role: !group managers

    #         # secrets-managers has role secrets-users
    #         - !grant
    #           member: !group managers
    #           role: !group consumers
    #     TEMPLATE
    #   end
    # end
  end
end

def add_replica_set(conjur_client:, name:, hosts:[], account:)
  replica_set = "conjur/partial-replication-sets/#{name}"
  puts "replica_set: #{replica_set}"
  # Generate and load replica policy
  puts conjur_client.load_policy(
    'conjur/partial-replication-sets',
    PolicyGenerator::Templates::ReplicaSet.template(replicaset_id: name)
  )
  # Add hosts to the replica set
  hosts.each do |host|
    conjur_client.load_policy(
      replica_set,
      PolicyGenerator::Templates::PartialReplicaHost.template(host: host)
    )
  end
  # Generate a UUID for the replica set
  uuid = SecureRandom.uuid
  conjur_client.resource([
    account,
    'variable',
    "#{replica_set}/replica-id"
  ].join(':')).add_value(uuid)

  # Generate the PGLogical record set
  Sequel.connect('postgres://postgres:Password123@pg-leader/postgres') do |db|
    db.run("SELECT pglogical.create_replication_set('#{uuid}')")
    db.run("SELECT pglogical.replication_set_add_table(set_name:= '#{uuid}', relation := 'public.resources', row_filter:= 'resource_id ~* '':group:|:host:|:policy:|:webservice:|:layer:|:user:'' or is_resource_visible(resource_id, ''#{account}:group:#{replica_set}/replicated-data'')')")
    db.run("SELECT pglogical.replication_set_add_table(set_name:= '#{uuid}', relation := 'public.secrets', row_filter:= 'is_resource_visible(resource_id, ''#{account}:group:#{replica_set}/replicated-data'')')")
  end
  puts "-- replica set completed --"
end

def configure_partial_replica_follower(host:, conjur_client:, docker_host:)
  # Generate a unique node and subscription
  subscriber = "#{host.gsub(/\W/, '_')}_#{SecureRandom.hex(3)}"
  subscription = "#{subscriber}_subscription"
  puts "subscription: #{subscription}"

  # Retrieve host's replica-set replica id
  replica_set_variable = conjur_client.resources(kind: 'variable', search: 'replica-id').first
  replica_set_name = replica_set_variable.id.to_s.split(':').last.split('/')[0..-2].join('/')
  puts "replica_set_name: #{replica_set_name}"
  replica_set_id = replica_set_variable.value
  puts "replica_set_id: #{replica_set_id}"
  # return

  Sequel.connect("postgres://postgres:Password123@#{docker_host}/postgres") do |db|
    db.run('CREATE EXTENSION IF NOT EXISTS pglogical')
    # sleep(5)
    db.run("SELECT pglogical.create_node( node_name := '#{subscriber}', dsn := 'host=#{docker_host} port=5432 dbname=postgres user=postgres password=Password123' )")
    # sleep(5)

    # Create subscription for this record set
    db.run("SELECT pglogical.create_subscription(subscription_name := '#{subscription}', replication_sets := '{default,#{replica_set_id}}', provider_dsn := 'host=pg-leader port=5432 dbname=postgres user=postgres password=Password123' )")
    # , synchronize_structure := true, synchronize_data := true
    puts 'waiting for replication to complete'
    db.run("SELECT pglogical.wait_for_subscription_sync_complete('#{subscription}')")
    puts 'replication complete'

    # Delete all the Foreign keys that exist connecting to the `resources` table so
    # we can perform table resynchronization
    db.run('ALTER TABLE public.secrets DROP CONSTRAINT secrets_resource_id_fkey')
    db.run('ALTER TABLE public.roles DROP CONSTRAINT roles_policy_id_fkey')
    db.run('ALTER TABLE public.role_memberships DROP CONSTRAINT role_memberships_policy_id_fkey')
    db.run('ALTER TABLE public.permissions DROP CONSTRAINT permissions_policy_id_fkey')
    db.run('ALTER TABLE public.permissions DROP CONSTRAINT permissions_resource_id_fkey')
    db.run('ALTER TABLE public.annotations DROP CONSTRAINT annotations_resource_id_fkey')
    db.run('ALTER TABLE public.annotations DROP CONSTRAINT annotations_policy_id_fkey')
    db.run('ALTER TABLE public.policy_versions DROP CONSTRAINT policy_versions_resource_id_fkey')
    db.run('ALTER TABLE public.host_factory_tokens DROP CONSTRAINT host_factory_tokens_resource_id_fkey')
    db.run('ALTER TABLE public.resources_textsearch DROP CONSTRAINT resources_textsearch_resource_id_fkey')
    db.run('ALTER TABLE public.authenticator_configs DROP CONSTRAINT authenticator_configs_resource_id_fkey')

    # Create triggers and function to handle permission modifications
    db.run("CREATE OR REPLACE FUNCTION sync_secrets_resources_on_delete() RETURNS TRIGGER AS $$
              BEGIN
                PERFORM pglogical.alter_subscription_resynchronize_table('#{subscription}', 'secrets');
                PERFORM pglogical.alter_subscription_resynchronize_table('#{subscription}', 'resources');
                RETURN OLD;
              END;
            $$ LANGUAGE plpgsql;")
    db.run("CREATE OR REPLACE FUNCTION sync_secrets_resources_on_insert_or_update() RETURNS TRIGGER AS $$
              BEGIN
                PERFORM pglogical.alter_subscription_resynchronize_table('#{subscription}', 'secrets');
                PERFORM pglogical.alter_subscription_resynchronize_table('#{subscription}', 'resources');
                RETURN NEW;
              END;
            $$ LANGUAGE plpgsql;")


    db.run("CREATE OR REPLACE TRIGGER replicate_relevant_data_on_insert
              AFTER INSERT ON public.role_memberships
              FOR EACH ROW
              WHEN (NEW.member_id like '%:group:#{replica_set_name}/replicated-data')
              EXECUTE FUNCTION sync_secrets_resources_on_insert_or_update();")
    db.run("ALTER TABLE public.role_memberships ENABLE REPLICA TRIGGER replicate_relevant_data_on_insert;")

    db.run("CREATE OR REPLACE TRIGGER replicate_relevant_data_on_update
              AFTER UPDATE ON public.role_memberships
              FOR EACH ROW
              WHEN (NEW.member_id like '%:group:#{replica_set_name}/replicated-data' OR OLD.member_id like '%:group:#{replica_set_name}/replicated-data')
              EXECUTE FUNCTION sync_secrets_resources_on_insert_or_update();")
    db.run("ALTER TABLE public.role_memberships ENABLE REPLICA TRIGGER replicate_relevant_data_on_update;")

    db.run("CREATE OR REPLACE TRIGGER replicate_relevant_data_on_delete
              AFTER DELETE ON public.role_memberships
              FOR EACH ROW
              WHEN (OLD.member_id like '%:group:#{replica_set_name}/replicated-data')
              EXECUTE FUNCTION sync_secrets_resources_on_delete();")
    db.run("ALTER TABLE public.role_memberships ENABLE REPLICA TRIGGER replicate_relevant_data_on_delete;")
  end
end

def setup_leader(name: 'leader-1', host: 'pg-leader', conjur_client:)
  # Create base policy for partial replication
  conjur_client.load_policy(
    'root',
    <<~TEMPLATE
    - !group conjur-administrators

    - !grant
      member: !user admin
      role: !group conjur-administrators

      - !policy
      id: conjur
      body:
      - !policy
        id: replication-sets
        owner: !group conjur-administrators
    TEMPLATE
  )

  # Install & configure pglogical
  Sequel.connect('postgres://postgres:Password123@pg-leader/postgres') do |db|
    # Install
    db.run('CREATE EXTENSION IF NOT EXISTS pglogical')

    # Create Node
    db.run("SELECT pglogical.create_node(node_name := '#{name}', dsn := 'host=#{host} port=5432 dbname=postgres user=postgres password=Password123')")

    # Add tables to 'default' replica
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.annotations')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.authenticator_configs')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.credentials')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.host_factory_tokens')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.permissions')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.policy_versions')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.role_memberships')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.roles')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'public.slosilo_keystore')")
  end
end

def load_data(application_count:)
  leader_api = client(url: 'conjur-leader', host: 'admin', api_key: ADMIN_API_KEY)
  leader_api.load_policy(
    'root',
    <<~TEMPLATE
    - !group team_leads
    - !group security_ops

    # Define "staging" namespace, owned by the "team_leads"
    - !policy
      id: staging
      owner: !group team_leads

    # Define "production" namespace, owned by the "security_ops" team
    - !policy
      id: production
      owner: !group security_ops
    TEMPLATE
  )
  puts '----'
  %w(staging production).each do |environment|
    (1..application_count).each do |number|
      puts "loading policy for: #{environment}/my-app-#{number}"
      leader_api.load_policy(
        environment,
        <<~TEMPLATE
          - !policy my-app-#{number}
        TEMPLATE
      )
      leader_api.load_policy(
        "#{environment}/my-app-#{number}",
        <<~TEMPLATE
        - !policy
          id: application
          body:
          - !layer
        TEMPLATE
      )
      leader_api.load_policy(
        "#{environment}/my-app-#{number}",
        <<~TEMPLATE
        - !policy
          id: database-connection
          body:
            - &variables
              - !variable username
              - !variable password
              - !variable url
              - !variable port
              - !variable database-type

            - !group consumers
            - !group managers

            # consumers can read and execute
            - !permit
              resource: *variables
              privileges: [ read, execute ]
              role: !group consumers

            # managers can update (and read and execute, via role grant)
            - !permit
              resource: *variables
              privileges: [ update ]
              role: !group managers

            # secrets-managers has role secrets-users
            - !grant
              member: !group managers
              role: !group consumers
        TEMPLATE
      )
      leader_api.load_policy(
        "#{environment}/my-app-#{number}",
        <<~TEMPLATE
        - !grant
          member: !layer application
          role: !group database-connection/consumers
        TEMPLATE
      )
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/database-connection/password").add_value(SecureRandom.hex(12))
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/database-connection/port").add_value('5432')
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/database-connection/url").add_value("#{environment}.postgres.databases.mycompany.com")
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/database-connection/username").add_value("#{environment}-my-app-#{number}-username")
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/database-connection/database-type").add_value('postgresql')
    end
  end
end

def client(url: 'conjur-leader', host: 'admin', api_key: ADMIN_API_KEY, account: ACCOUNT)
  Conjur.configuration.account = account
  Conjur.configuration.appliance_url = "http://#{url}"
  Conjur::API.new_from_key(host, api_key)
end

def replicate_follower(number:)
  configure_partial_replica_follower(
    host: "follower-#{number}.mycompany.com",
    docker_host: "pg-follower-#{number}",
    # docker_host: "dap-follower-syncer_pg-follower_#{number}",
    conjur_client: client(
      host: "host/conjur/replication-sets/replica-set-#{number}/follower-#{number}.mycompany.com",
      api_key: client.resource("#{ACCOUNT}:host:conjur/replication-sets/replica-set-#{number}/follower-#{number}.mycompany.com").rotate_api_key
    )
  )
end

namespace :partial_replication do
  task :rotate, [:app] do |_, args|
    leader_api = client(url: 'conjur-leader', host: 'admin', api_key: ADMIN_API_KEY)
    %w(staging production).each do |environment|
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{args[:app]}/database-connection/password").add_value(SecureRandom.hex(12))
    end
  end

  task :demo, [:count] do |_, args|
    count = args[:count].to_i
    # Configure a new "leader"
    setup_leader(conjur_client: client)

    # Load some data for replication
    load_data(application_count: count)

    # Add two replica-sets to Conjur
    (1..count).each do |item|
      add_replica_set(
        conjur_client: client,
        name: "replica-set-#{item}",
        hosts: ["follower-#{item}.mycompany.com"],
        account: ACCOUNT
      )
      client.load_policy(
        'root',
        <<~TEMPLATE
        - !grant
          member: !group conjur/replication-sets/replica-set-#{item}/replicated-data
          role: !group production/my-app-#{item}/database-connection/consumers
        TEMPLATE
      )
    end
    # sleep(5)
    # exit

    # {
    #   'us-east-replica-set': [
    #     'follower-1.mycompany.com',
    #     'follower-2.mycompany.com'
    #   ],
    #   'us-west-replica-set': [
    #     'follower-3.mycompany.com',
    #     'follower-4.mycompany.com'
    #   ]
    # }.each do |replicaset_id, hosts|
    #   add_replica_set(
    #     conjur_client: client,
    #     name: replicaset_id,
    #     hosts: hosts,
    #     account: ACCOUNT
    #   )
    # end

    # Grant `us-east-replica-set` access to all credentials in:
    # - production/my-app-1/postgres-database
    # - production/my-app-2/postgres-database
    # - production/my-app-3/postgres-database
    # client.load_policy('root', File.read('policy/follower-grant.yml'))

    # Deploy a partial replication follower: `follower-1.mycompany.com`
    # configure_partial_replica_follower(
    #   host: 'follower-9.mycompany.com',
    #   docker_host: 'dap-follower-syncer_pg-follower_9',
    #   conjur_client: client(
    #     host: 'host/conjur/members/followers/replica-set-9/follower-9.mycompany.com',
    #     api_key: client.resource("#{ACCOUNT}:host:conjur/members/followers/replica-set-9/follower-9.mycompany.com").rotate_api_key
    #   )
    # )
    (1..count).each do |counter|
      replicate_follower(number: counter)
    end
    # replicate_follower(number: 2)


    # exit
  end

  # task :setup_leader do
  #   # leader_api = client(url: 'conjur-leader', host: 'admin', api_key: ADMIN_API_KEY)
  #   client.load_policy('root', File.read('policy/partial-replication/base.yml'))
  #   # leader_api.load_policy('conjur/members/followers', File.read('policy/partial-replication/replica.yml'))
  #   # puts leader_api.load_policy('conjur/members/followers', File.read('policy/partial-replication/follower.yml'))

  #   # Setup Leader
  #   Sequel.connect('postgres://postgres:Password123@pg-leader/postgres') do |db|
  #     # install & configure pglogical
  #     db.run('CREATE EXTENSION IF NOT EXISTS pglogical')
  #     db.run("SELECT pglogical.create_node(node_name := 'provider1', dsn := 'host=pg-leader port=5432 dbname=postgres user=postgres password=Password123')")

  #     # create default replica set
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'annotations')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'authenticator_configs')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'credentials')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'host_factory_tokens')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'permissions')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'policy_versions')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'role_memberships')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'roles')")
  #     db.run("SELECT pglogical.replication_set_add_table('default', 'slosilo_keystore')")

  #     # db.run("SELECT pglogical.drop_replication_set(set_name := 'follower-1');")
  #     # db.run("SELECT pglogical.create_replication_set('follower-1')")
  #     # db.run("SELECT pglogical.replication_set_add_table(set_name:= 'follower-1', relation := 'resources', row_filter:= 'resource_id ~* '':group:|:host:|:policy:|:webservice:|:layer:|:user:'' or is_resource_visible(resource_id, ''default:group:conjur/members/followers/replica-1/replicated-data'')')")
  #     # db.run("SELECT pglogical.replication_set_add_table(set_name:= 'follower-1', relation := 'secrets', row_filter:= 'is_resource_visible(resource_id, ''default:group:conjur/members/followers/replica-1/replicated-data'')')")
  #   end
  # end

  # task :setup_follower do

  #   subscriber = 'Follower-1'
  #   subscription = "#{subscriber}-subscription"


  #   # Setup Follower
  #   Sequel.connect('postgres://postgres:Password123@pg-follower-1/postgres') do |db|
  #     # db.run("ALTER TABLE resources ADD COLUMN timestamp TIMESTAMP;")
  #     # db.run("ALTER TABLE secrets ADD COLUMN timestamp TIMESTAMP;")


  #     db.run('CREATE EXTENSION pglogical')
  #     db.run("SELECT pglogical.create_node( node_name := '#{subscriber}', dsn := 'host=pg-follower-1 port=5432 dbname=postgres user=postgres password=Password123' )")

  #     # Delete all the Foreign keys that exist on the `resources` table
  #     db.run("ALTER TABLE roles DROP CONSTRAINT roles_policy_id_fkey")
  #     db.run("ALTER TABLE role_memberships DROP CONSTRAINT role_memberships_policy_id_fkey")
  #     db.run("ALTER TABLE permissions DROP CONSTRAINT permissions_policy_id_fkey")
  #     db.run("ALTER TABLE permissions DROP CONSTRAINT permissions_resource_id_fkey")
  #     db.run("ALTER TABLE annotations DROP CONSTRAINT annotations_resource_id_fkey")
  #     db.run("ALTER TABLE annotations DROP CONSTRAINT annotations_policy_id_fkey")
  #     db.run("ALTER TABLE policy_versions DROP CONSTRAINT policy_versions_resource_id_fkey")
  #     db.run("ALTER TABLE host_factory_tokens DROP CONSTRAINT host_factory_tokens_resource_id_fkey")
  #     db.run("ALTER TABLE resources_textsearch DROP CONSTRAINT resources_textsearch_resource_id_fkey")
  #     db.run("ALTER TABLE authenticator_configs DROP CONSTRAINT authenticator_configs_resource_id_fkey")

  #     # db.run("select pglogical.drop_subscription(subscription_name := 'subscription1')")
  #     db.run("SELECT pglogical.create_subscription(subscription_name := '#{subscription}', replication_sets := '{default,follower-1}', provider_dsn := 'host=pg-leader port=5432 dbname=postgres user=postgres password=Password123' )")

  #     # Create triggers and function to handle permission modifications
  #     db.run("CREATE OR REPLACE FUNCTION sync_secrets_resources() RETURNS TRIGGER AS $$
  #               BEGIN
  #                 PERFORM pglogical.alter_subscription_resynchronize_table('#{subscription}', 'secrets');
  #                 PERFORM pglogical.alter_subscription_resynchronize_table('#{subscription}', 'resources');
  #               END;
  #             $$ LANGUAGE plpgsql;")
  #     db.run("CREATE OR REPLACE TRIGGER replicate_relevant_data_on_insert
  #               AFTER INSERT ON role_memberships
  #               FOR EACH ROW
  #               WHEN (NEW.member_id like '%:group:conjur/members/followers/%/replicated-data')
  #               EXECUTE FUNCTION sync_secrets_resources();")
  #     db.run("CREATE OR REPLACE TRIGGER replicate_relevant_data_on_update
  #               AFTER UPDATE ON role_memberships
  #               FOR EACH ROW
  #               WHEN (NEW.member_id like '%:group:conjur/members/followers/%/replicated-data' OR OLD.member_id like '%:group:conjur/members/followers/%/replicated-data')
  #               EXECUTE FUNCTION sync_secrets_resources();")
  #     db.run("CREATE OR REPLACE TRIGGER replicate_relevant_data_on_delete
  #               AFTER DELETE ON role_memberships
  #               FOR EACH ROW
  #               WHEN (OLD.member_id like '%:group:conjur/members/followers/%/replicated-data')
  #               EXECUTE FUNCTION sync_secrets_resources();")
  #   end
  # end

  # task :touch do
  #   Sequel.connect('postgres://postgres:Password123@pg-leader/postgres') do |db|
  #     db.run("UPDATE resources SET timestamp = NOW() where resource_id in (select resource_id from visible_resources('default:group:conjur/members/followers/replica-1/replicated-data'));")
  #     db.run("UPDATE secrets SET timestamp = NOW() where resource_id in (select resource_id from visible_resources('default:group:conjur/members/followers/replica-1/replicated-data'));")
  #     # %w[resources secrets].each do |table|
  #     #   db.run("UPDATE #{table} SET timestamp = NOW();")
  #     # end
  #   end
  # end

  task :reset_follower do
    Sequel.connect('postgres://postgres:Password123@pg-follower-1/postgres') do |db|
      %w[annotations authenticator_configs credentials host_factory_tokens permissions policy_log policy_versions resources resources_textsearch role_memberships roles schema_migrations secrets slosilo_keystore].each do |table|
        db.run("DELETE FROM #{table};")
      end
      # db.run("SELECT pglogical.create_node( node_name := 'subscriber1', dsn := 'host=pg-follower-1 port=5432 dbname=postgres user=postgres password=Password123' )")
      exit
      db.run("SELECT pglogical.drop_subscription('subscription1');")
      db.run("SELECT pglogical.drop_node('subscriber1');")
      db.run("SELECT pglogical.create_node( node_name := 'subscriber1', dsn := 'host=pg-follower-1 port=5432 dbname=postgres user=postgres password=Password123' )")
      db.run("SELECT pglogical.create_subscription(subscription_name := 'subscription1', replication_sets := '{default,follower-1}', provider_dsn := 'host=pg-leader port=5432 dbname=postgres user=postgres password=Password123' )")
    end
  end

  task :delete do
    client(
      url: 'conjur-leader',
      host: 'admin',
      api_key: ADMIN_API_KEY
    ).load_policy(
      "root",
      File.read('policy/delete.yml'),
      method: :patch
    )
  end

  task :deny do
    client(
      url: 'conjur-leader',
      host: 'admin',
      api_key: ADMIN_API_KEY
    ).load_policy(
      "root",
      File.read('policy/deny.yml'),
      method: :patch
    )
  end

  task :add do
    client.load_policy(
      'root',
      File.read('policy/add.yml')
    )
  end

  task :update do
    client(
      url: 'conjur-leader',
      host: 'admin',
      api_key: ADMIN_API_KEY
    ).resource(
      'default:variable:production/my-app-2/postgres-database/password'
    ).add_value(
      SecureRandom.hex
    )
  end

  task :prepare_conjur do
    leader_api = client(url: 'conjur-leader', host: 'admin', api_key: ADMIN_API_KEY)
    leader_api.load_policy('root', File.read('policy/partial-replication/base.yml'))
    leader_api.load_policy('conjur/partial-replication-sets', File.read('policy/partial-replication/replica.yml'))
    puts leader_api.load_policy('conjur/partial-replication-sets', File.read('policy/partial-replication/follower.yml'))
  end
end
namespace :general do
  task :generate_compose, [:count] do |t, args|
    require 'erb'
    template = <<~TEMPLATE
      version: "3"
      services:
        pg-leader:
          build:
            context: ./
            dockerfile: 'Dockerfile.pg'
          environment:
            POSTGRES_PASSWORD: Password123
          volumes:
            - ./postgres/leader/postgres.conf:/etc/postgresql/postgresql.conf
            - ./postgres/leader/pg_hba.conf:/etc/postgresql/pg_hba.conf
          command: postgres -c config_file=/etc/postgresql/postgresql.conf
          ports:
            - 5432:5432
        conjur-leader:
          image: cyberark/conjur:latest
          command: server
          environment:
            DATABASE_URL: postgres://postgres:Password123@pg-leader/postgres
            CONJUR_DATA_KEY:
            CONJUR_AUTHENTICATORS:
            CONJUR_LOG_LEVEL: debug
            OPENSSL_FIPS_ENABLED: 'false'
          depends_on:
            - pg-leader
          links:
            - pg-leader
          restart: on-failure
          ports:
            - 8080:80
        client:
          image: cyberark/conjur-cli:5
          entrypoint: sleep
          command: infinity
          environment:
            CONJUR_APPLIANCE_URL: http://conjur-leader
            CONJUR_ACCOUNT: default
            CONJUR_AUTHN_LOGIN: admin
          links:
          - conjur-leader:conjur-leader
          volumes:
          - .:/src/
        dev-container:
          build: .
          links:
            - conjur-leader
            - pg-leader
          <%- (1..follower_count).each do |counter| -%>
            - pg-follower-<%= counter %>
          <%- end -%>
          volumes:
            - ./:/src/follower-syncer

      <%- (1..follower_count).each do |counter| -%>
        conjur-follower-<%= counter %>:
          image: cyberark/conjur:latest
          command: server
          environment:
            DATABASE_URL: postgres://postgres:Password123@pg-follower-<%= counter %>/postgres
            CONJUR_DATA_KEY:
            CONJUR_AUTHENTICATORS:
            OPENSSL_FIPS_ENABLED: 'false'
          depends_on:
            - pg-follower-<%= counter %>
          links:
            - pg-follower-<%= counter %>
          restart: on-failure
        pg-follower-<%= counter %>:
          build:
            context: ./
            dockerfile: 'Dockerfile.pg'
          environment:
            POSTGRES_PASSWORD: Password123
          volumes:
            - ./postgres/follower/postgres.conf:/etc/postgresql/postgresql.conf
            - ./postgres/follower/pg_hba.conf:/etc/postgresql/pg_hba.conf
          command: postgres -c config_file=/etc/postgresql/postgresql.conf
          ports:
            - "<%= 9000 + counter %>:5432"
          links:
            - pg-leader
      <%- end -%>
    TEMPLATE
    File.open("docker-compose-generated.yml", "w") do |f|
      f.write ERB.new(template, nil, '-').result_with_hash(
        { follower_count: args[:count].to_i }
      )
    end
  end
end
