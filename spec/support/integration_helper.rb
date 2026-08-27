# frozen_string_literal: true

require 'securerandom'

# Helpers for integration specs, which need a reachable Zammad instance.
class Helper
  class SetupError < StandardError; end

  def self.config
    {
      url:      ENV['TEST_URL']      || 'http://localhost:3000/',
      user:     ENV['TEST_USER']     || 'admin@example.com',
      password: ENV['TEST_PASSWORD'] || 'test'
    }
  end

  def self.client(**overrides)
    settings = config
    ZammadAPI::Client.new(
      url:      overrides.fetch(:url, settings[:url]),
      user:     overrides.fetch(:user, settings[:user]),
      password: overrides.fetch(:password, settings[:password]),
      **overrides.except(:url, :user, :password)
    )
  end

  # Makes sure the instance has an admin account, running Zammad's auto wizard
  # once per suite.
  #
  # Memoized and idempotent, so it does not matter which spec file happens to
  # run first, and re-running the suite against an already configured instance
  # is not an error.
  def self.ensure_configured!
    @ensure_configured ||= begin
      auto_wizard? || verify_setup_done!
      true
    end
  end

  # @return [Boolean] whether the auto wizard ran now
  def self.auto_wizard?
    response = connection.get('api/v1/getting_started/auto_wizard')
    parse(response.body)['auto_wizard_success'] == true
  end

  def self.verify_setup_done!
    started = parse(connection.get('api/v1/getting_started').body)
    return true if started['setup_done']

    raise SetupError, "Zammad at #{config[:url]} is not set up and the auto wizard did not run: #{started.inspect}"
  end

  def self.connection
    Faraday.new(url: config[:url])
  end

  def self.parse(body)
    JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  def self.random
    SecureRandom.random_number(99_999_999).to_s
  end

  private_class_method :verify_setup_done!, :connection, :parse
end
