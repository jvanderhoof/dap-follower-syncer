require 'securerandom'

require 'rubygems'
require 'bundler/setup'
require 'conjur/api'

require 'sequel'
require 'pry'

ADMIN_API_KEY = File.read("admin_data").split("\n").last.split(': ').last.strip
ACCOUNT = 'default'.freeze

module PolicyGenerator
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
              - !variable replica-id

              - !group replicated-data
              - !group

              - !permit
                resource: !variable replica-id
                privileges: [ read, execute ]
                role: !group

              # give replica-1 group the role replicated-data to allow
              # uses to mark data as "replicatable" for this follower
              - !grant
                member: !group
                role: !group replicated-data
        TEMPLATE
      end
    end
  end
end

def add_replica_set(conjur_client:, name:, hosts:[], account:)
  replica_set = "conjur/members/followers/#{name}"
  # Generate and load replica policy
  conjur_client.load_policy(
    'conjur/members/followers',
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
    db.run("SELECT pglogical.replication_set_add_table(set_name:= '#{uuid}', relation := 'resources', row_filter:= 'resource_id ~* '':group:|:host:|:policy:|:webservice:|:layer:|:user:'' or is_resource_visible(resource_id, ''#{account}:group:#{replica_set}/replicated-data'')')")
    db.run("SELECT pglogical.replication_set_add_table(set_name:= '#{uuid}', relation := 'secrets', row_filter:= 'is_resource_visible(resource_id, ''#{account}:group:#{replica_set}/replicated-data'')')")
  end
end

def configure_partial_replica_follower(host:, conjur_client:)
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

  Sequel.connect('postgres://postgres:Password123@pg-follower-1/postgres') do |db|
    db.run('CREATE EXTENSION IF NOT EXISTS pglogical')
    db.run("SELECT pglogical.create_node( node_name := '#{subscriber}', dsn := 'host=pg-follower-1 port=5432 dbname=postgres user=postgres password=Password123' )")

    # Create subscription for this record set
    db.run("SELECT pglogical.create_subscription(subscription_name := '#{subscription}', replication_sets := '{default,#{replica_set_id}}', provider_dsn := 'host=pg-leader port=5432 dbname=postgres user=postgres password=Password123' )")
    puts 'waiting for replication to complete'
    db.run("SELECT pglogical.wait_for_subscription_sync_complete('#{subscription}')")
    puts 'follower replication complete'

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

    # return
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
    puts 'Follower setup complete'
  end
end

def setup_leader(name: 'leader-1', host: 'pg-leader', conjur_client:)
  # Create base policy for partial replication
  conjur_client.load_policy('root', File.read('policy/partial-replication/base.yml'))
  # Install & configure pglogical
  Sequel.connect('postgres://postgres:Password123@pg-leader/postgres') do |db|
    # Install
    db.run('CREATE EXTENSION IF NOT EXISTS pglogical')

    # Create Node
    db.run("SELECT pglogical.create_node(node_name := '#{name}', dsn := 'host=#{host} port=5432 dbname=postgres user=postgres password=Password123')")

    # Add tables to 'default' replica
    db.run("SELECT pglogical.replication_set_add_table('default', 'annotations')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'authenticator_configs')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'credentials')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'host_factory_tokens')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'permissions')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'policy_versions')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'role_memberships')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'roles')")
    db.run("SELECT pglogical.replication_set_add_table('default', 'slosilo_keystore')")
  end
end

def load_data
  leader_api = client(url: 'conjur-leader', host: 'admin', api_key: ADMIN_API_KEY)
  puts leader_api.load_policy('root', File.read('policy/root.yml'))
  %w(staging production).each do |environment|
    leader_api.load_policy(environment, File.read('policy/apps/applications.yml'))
    (1..6).each do |number|
      leader_api.load_policy("#{environment}/my-app-#{number}",  File.read('policy/apps/generic-application.yml'))
      leader_api.load_policy("#{environment}/my-app-#{number}",  File.read('policy/services/pg-database.yml'))
      leader_api.load_policy("#{environment}/my-app-#{number}",  File.read('policy/pg-entitlement.yml'))

      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/postgres-database/password").add_value SecureRandom.hex(12)
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/postgres-database/port").add_value "5432"
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/postgres-database/url").add_value "#{environment}.postgres.databases.mycompany.com"
      leader_api.resource("#{ACCOUNT}:variable:#{environment}/my-app-#{number}/postgres-database/username").add_value "#{environment}-my-app-#{number}-username"
    end
  end
end

def client(url: 'conjur-leader', host: 'admin', api_key: ADMIN_API_KEY, account: ACCOUNT)
  Conjur.configuration.account = account
  Conjur.configuration.appliance_url = "http://#{url}"
  Conjur::API.new_from_key(host, api_key)
end

namespace :partial_replication do
  task :demo do
    # Configure a new "leader"
    setup_leader(conjur_client: client)

    # Load some data for replication
    load_data

    # Add two replica-sets to Conjur
    {
      'us-east-replica-set': [
        'follower-1.mycompany.com',
        'follower-2.mycompany.com'
      ],
      'us-west-replica-set': [
        'follower-3.mycompany.com',
        'follower-4.mycompany.com'
      ]
    }.each do |replicaset_id, hosts|
      add_replica_set(
        conjur_client: client,
        name: replicaset_id,
        hosts: hosts,
        account: ACCOUNT
      )
    end

    # Grant `us-east-replica-set` access to all credentials in:
    # - production/my-app-1/postgres-database
    # - production/my-app-2/postgres-database
    # - production/my-app-3/postgres-database
    client.load_policy('root', File.read('policy/follower-grant.yml'))

    # Deploy a partial replication follower: `follower-1.mycompany.com`
    configure_partial_replica_follower(
      host: 'follower-1.mycompany.com',
      conjur_client: client(
        host: 'host/conjur/members/followers/us-east-replica-set/follower-1.mycompany.com',
        api_key: client.resource("#{ACCOUNT}:host:conjur/members/followers/us-east-replica-set/follower-1.mycompany.com").rotate_api_key
      )
    )
  end
end
