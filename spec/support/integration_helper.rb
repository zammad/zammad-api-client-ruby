# frozen_string_literal: true

require 'securerandom'

# Helpers for integration specs, which need a reachable Zammad instance.
class Helper
  class SetupError < StandardError; end

  # The Zammad the integration specs run against, where one was named.
  #
  # There is no default. These specs run the auto wizard and then create,
  # change and delete groups, organizations, users, tickets, states and
  # priorities, and `http://localhost:3000/` used to stand in for a TEST_URL
  # that was not set. That is where a Zammad under development listens, and
  # a bare `rspec` runs these files along with the unit specs, so the
  # commonest way to run the suite wrote test records into whatever was
  # there. Where to write is for whoever runs them to say.
  #
  # @return [String, nil] nil when TEST_URL is not set
  def self.target
    url = ENV['TEST_URL'].to_s.strip
    url.empty? ? nil : url
  end

  # Where no TEST_URL is set, a URL nothing answers at stands in for it. The
  # spec files build their client while they are loaded, which is before
  # RSpec has left their examples out, so this cannot raise; the examples
  # never run, and {.ensure_configured!} refuses them if they are made to.
  # `.invalid` is reserved for names that never resolve.
  UNSET_URL = 'http://test-url-not-set.invalid/'

  def self.config
    {
      url:      target || UNSET_URL,
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
  # The failure is memoized alongside the success, because `||=` memoizes
  # neither. A TEST_URL with nothing behind it re-ran the whole probe - two
  # requests, each with a ten second open timeout - once per example, so a
  # Zammad that never came up took the suite a very long time to say so.
  def self.ensure_configured!
    raise SetupError, 'TEST_URL is not set, so there is no Zammad to run the integration specs against' if target.nil?
    return true if @ensure_configured
    raise @setup_failure if @setup_failure

    begin
      auto_wizard? || verify_setup_done!
      @ensure_configured = true
    rescue SetupError => e
      @setup_failure = e
      raise
    end
  end

  # @return [Boolean] whether the auto wizard ran now
  # @raise [SetupError] when the instance cannot be reached at all
  def self.auto_wizard?
    response = connection.get('api/v1/getting_started/auto_wizard')
    parse(response.body)['auto_wizard_success'] == true
  rescue Faraday::Error => e
    # {.verify_setup_done!} wraps its failure into a SetupError naming the URL
    # and the user; this probe runs one line earlier and did not, so the
    # commonest failure of all - CI booting against a Zammad that never came
    # up - reached every example as a bare Faraday exception from a helper
    # that exists to explain exactly that.
    raise SetupError,
          "Zammad at #{config[:url]} could not be reached: the setup check failed to connect " \
          "(#{e.class}: #{e.message}). Set TEST_URL to a running instance."
  end

  # A configured Zammad requires authentication even for
  # /api/v1/getting_started, so the setup state cannot be read from there.
  # Proving that the configured credentials work answers the only question
  # that matters here.
  def self.verify_setup_done!
    ZammadAPI::Client.new(**config).groups.all.page(1, per_page: 1).to_a
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
