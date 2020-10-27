require 'json'
require 'yaml'
require 'securerandom'

require 'rubygems'
require 'bundler/setup'
require 'conjur/api'

namespace :syncer do

  def source_api
    @source_api ||= api(name: 'dap-source')
  end

  def destination_api
    @destination_api ||= api(name: 'dap-destination')
  end

  def api(name:)
    OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_file("/opt/#{name.split('-').last}/conjur/etc/ssl/#{name}.pem")
    Conjur.configuration.account = 'demo'
    Conjur.configuration.appliance_url = "https://#{name}/api"
    api_key = Conjur::API.login('admin', 'MySecretP@ss1')
    Conjur::API.new_from_key('admin', api_key)
  end

  task :check do
    source_api
    destination_api
  end

  task :load_data do
    source_api.load_policy('root',  File.read('policy/root.yml'))
    %w(staging production).each do |environment|
      source_api.load_policy(environment,  File.read('policy/apps/applications.yml'))
      (1..6).each do |number|
        source_api.load_policy("#{environment}/my-app-#{number}",  File.read('policy/apps/generic-application.yml'))
        source_api.load_policy("#{environment}/my-app-#{number}",  File.read('policy/services/pg-database.yml'))
        source_api.load_policy("#{environment}/my-app-#{number}",  File.read('policy/pg-entitlement.yml'))

        source_api.resource("demo:variable:#{environment}/my-app-#{number}/postgres-database/password").add_value SecureRandom.hex(12)
        source_api.resource("demo:variable:#{environment}/my-app-#{number}/postgres-database/port").add_value "5432"
        source_api.resource("demo:variable:#{environment}/my-app-#{number}/postgres-database/url").add_value "#{environment}.postgres.databases.mycompany.com"
        source_api.resource("demo:variable:#{environment}/my-app-#{number}/postgres-database/username").add_value "#{environment}-my-app-#{number}-username"
      end
    end
  end

  task :prepare_replication do
    destination_api.load_policy('root',  File.read('policy/root.yml'))
  end

  task :replicate do
    policies = source_api.resources(kind: 'policy')
    variables = {}.tap do |hsh|
      source_api.resources(kind: 'variable').each do |variable|
        next unless variable.attributes['id'].starts_with?('demo:variable:production')
        hsh[variable.attributes['id']] = source_api.resource(variable.attributes['id']).value
      end
    end

    destination_api.load_policy('root',  File.read('policy/root.yml'))

    policies.each do |policy|
      next unless [policy.attributes['id'], policy.attributes['policy_id']].include?("demo:policy:production") ||
      policy.attributes['id'].starts_with?('demo:policy:production')
      next if policy.attributes['policy_versions'].empty?
      puts "importing policy: #{policy.attributes['id']}"
      policy.attributes['policy_versions'].each do |policy_version|
        destination_api.load_policy(policy.attributes['id'].split(':').last,  policy_version['policy_text'])
      end
    end

    variables.each do |id, value|
      puts "importing variable: #{id}"
      destination_api.resource(id).add_value(value)
    end
  end
   

end