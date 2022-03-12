require 'securerandom'

require 'rubygems'
require 'bundler/setup'
require 'conjur/api'

require 'sequel'
require 'pry'

ADMIN_API_KEY = '2bhmwyd374mrp62xdr9xs2p99xnn3td9fff1kbzm3bbeewwh27zkgg2'.freeze
ACCOUNT = 'default'.freeze

namespace :partial_replication do
  task :setup do
    # Setup Leader
    Sequel.connect('postgres://postgres:Password123@pg-leader/postgres') do |db|
      db.run('CREATE EXTENSION pglogical')
      db.run("SELECT pglogical.create_node(node_name := 'provider1', dsn := 'host=pg-leader port=5432 dbname=postgres user=postgres password=Password123')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'annotations')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'authenticator_configs')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'credentials')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'host_factory_tokens')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'permissions')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'policy_versions')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'role_memberships')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'roles')")
      db.run("SELECT pglogical.replication_set_add_table('default', 'slosilo_keystore')")
      db.run("SELECT pglogical.create_replication_set('follower-1')")
      db.run("SELECT pglogical.replication_set_add_table(set_name:= 'follower-1', relation := 'resources', row_filter:= 'resource_id ~* '':group:|:host:|:policy:|:webservice:|:layer:|:user:'' or is_resource_visible(resource_id, ''default:host:conjur/members/followers/partial-follower-1'')')")
      db.run("SELECT pglogical.replication_set_add_table(set_name:= 'follower-1', relation := 'secrets', row_filter:= 'is_resource_visible(resource_id, ''default:host:conjur/members/followers/partial-follower-1'')')")
    end

    # Setup Follower
    Sequel.connect('postgres://postgres:Password123@pg-follower-1/postgres') do |db|
      db.run('CREATE EXTENSION pglogical')
      db.run("SELECT pglogical.create_node( node_name := 'subscriber1', dsn := 'host=pg-follower-1 port=5432 dbname=postgres user=postgres password=Password123' )")
      db.run("SELECT pglogical.create_subscription( subscription_name := 'subscription1', replication_sets := '{default,follower-1}', provider_dsn := 'host=pg-leader port=5432 dbname=postgres user=postgres password=Password123' )")
    end
  end

  def client(url:, host:, api_key:, account: ACCOUNT)
    Conjur.configuration.account = account
    Conjur.configuration.appliance_url = "http://#{url}"
    Conjur::API.new_from_key(host, api_key)
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

  task :load_data do
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
    leader_api.load_policy('root', File.read('policy/follower-grant.yml'))
  end
end
