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

  # A configured Zammad requires authentication even for
  # /api/v1/getting_started, so the setup state cannot be read from there.
  # Proving that the configured credentials work answers the only question
  # that matters here.
  def self.verify_setup_done!
    ZammadAPI::Client.new(**config).group.all.page(1, of: 1).to_a
    true
  rescue ZammadAPI::Error => e
    raise SetupError,
          "Zammad at #{config[:url]} is not usable: the auto wizard did not run and " \
          "authenticating as #{config[:user]} failed (#{e.class}: #{e.message})"
  end

  # Finite timeouts matter here: a TEST_URL that accepts the connection but
  # never answers would otherwise hang the integration job until the CI
  # timeout rather than failing the setup check.
  def self.connection
    Faraday.new(url: config[:url], request: { open_timeout: 10, timeout: 30 })
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

# Each integration spec file walks one record through its lifecycle - new,
# save, find, destroy - and every step asserts on what the previous one left
# behind, so the record is shared across ordered examples.
#
# That coupling is fine as long as the whole file runs in definition order,
# and silent nonsense as soon as it does not: `--only-failures`, `-e 'save'`
# or a `--seed` reordering used to fail as `NoMethodError: undefined method
# 'save' for nil`, which says nothing about the actual cause. This says it.
module LifecycleState
  def established!(record, example)
    return record if record

    raise "this example continues the record built by '#{example}', which did not run in this process. " \
          'These examples share one record and have to run as a whole file, in definition order.'
  end
end
