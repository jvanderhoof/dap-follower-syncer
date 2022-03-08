require 'json'
require 'yaml'
require 'securerandom'

require 'rubygems'
require 'bundler/setup'
require 'conjur/api'

# require 'pg'
require 'sequel'
require 'pry'

ADMIN_API_KEY = '1vjncas3ef0amx2gsddxm7wd9sz7jbqct1j0zzh12nk81dn37w7pfq'.freeze
FOLLOWER_API_KEY = '39xe8hs3h847a72yyadnq14v6fq3rgj2ks22qe45t15fvvkd1rxxevc'.freeze
ACCOUNT = 'default'.freeze

module Replication
  class VariableReader
    def initialize(client:)
      @client = client
    end

    # Returns a hash where the variable is the key and the corresponding
    # value is the variable value.
    #
    # IMPORTANT: we need to gather ALL the information from the leader
    # before connecting to the follower as the the Conjur API gem uses
    # a Singleton for setting connection information.
    def read(variables: [])
      if variables.is_a?(Array)
        variables.map do |variable|
          @client.resource(variable)
        end
      else
        @client.resources(kind: 'variable')
      end.each_with_object({}) do |variable, hsh|
        hsh[variable.id.to_s] = variable.value
      end
    end
  end

  class VariableWriter
    def initialize(client:)
      @client = client
    end

    def write(variables:)
      variables.each do |variable, value|
        puts "updating '#{variable}' to '#{value}'"
        @client.resource(variable).add_value(value)
      end
    end
  end
end

namespace :partial_replication do
  task :setup do
    LEADER = Sequel.connect('postgres://postgres:Password123@pg-leader/postgres')
    LEADER.execute('show WAL_LEVEL;') do |result|
      raise 'Leader must be configured with Logical Replication' if result.first['wal_level'] != 'logical'
    end
    LEADER.execute('CREATE PUBLICATION partial_replica_publication FOR TABLE annotations,authenticator_configs,credentials,host_factory_tokens,permissions,policy_log,policy_versions,resources,resources_textsearch,role_memberships,roles,slosilo_keystore;')

    FOLLOWER = Sequel.connect('postgres://postgres:Password123@pg-follower-1/postgres')
    FOLLOWER.execute("CREATE SUBSCRIPTION partial_replica_subscription CONNECTION 'host=pg-leader port=5432 dbname=postgres password=Password123' PUBLICATION partial_replica_publication;")
  end

  task :notify do
    LEADER = Sequel.connect('postgres://postgres:Password123@pg-leader/postgres')
    LEADER.notify(:variable_changes, payload:
      {
        variable: 'default:variable:production/my-app-2/postgres-database/username',
        action: 'updated'
      }.to_json
    )
  end

  task :listen do
    LEADER = Sequel.connect('postgres://postgres:Password123@pg-leader/postgres')
    LEADER.listen(:variable_changes, loop: true) do |channel, pid, payload|
      puts "Recieved payload '#{payload}' on channel '#{channel}'"
      payload = JSON.parse(payload)
      replicate(variables: [payload['variable']])
    end
  end

  def replicate(variables:)
    changed_variables = Replication::VariableReader.new(
      client: client(
        url: 'conjur-leader',
        host: 'host/conjur/members/followers/partial-follower-1',
        api_key: FOLLOWER_API_KEY
      )
    ).read(variables: variables)
    Replication::VariableWriter.new(
      client: client(
        url: 'conjur-follower-1',
        host: 'admin',
        api_key: ADMIN_API_KEY
      )
    ).write(
      variables: changed_variables
    )
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
    LEADER = Sequel.connect('postgres://postgres:Password123@pg-leader/postgres')
    LEADER.notify(:variable_changes, payload:
      {
        variable: 'default:variable:production/my-app-2/postgres-database/password',
        action: 'updated'
      }.to_json
    )

  end

  task :replicate do
    replicate(variables: :all)
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
