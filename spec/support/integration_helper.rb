# frozen_string_literal: true

require 'securerandom'
require_relative '../../script/live_target'

# Helpers for integration specs, which need a reachable Zammad instance.
class Helper
  class SetupError < StandardError; end

  # The Zammad the integration specs run against, where one was named.
  #
  # There is no default. These specs run the auto wizard and then create,
  # change and delete records, a bare `rspec` loads them along with the unit
  # specs, and `http://localhost:3000/` is where a Zammad under development
  # listens. Where to write is for whoever runs them to say.
  #
  # Asked of {LiveTarget}, which rake and script/check_connection.rb ask
  # as well, so that the three agree on whether a target was named.
  #
  # @return [String, nil] nil when TEST_URL is not set
  def self.target = LiveTarget.url

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
  # is not an error. The failure is memoized alongside the success, so that a
  # TEST_URL with nothing behind it is probed once rather than once per
  # example, each probe waiting out its timeouts.
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

  # The body is asked about only where it is a JSON object: valid JSON that
  # is not one - `null`, a list, a number - is no answer. Anything but an
  # object saying the wizard ran leaves {.verify_setup_done!} to decide.
  #
  # @return [Boolean] whether the auto wizard ran now
  # @raise [SetupError] when the instance cannot be reached at all
  def self.auto_wizard?
    response = connection.get('api/v1/getting_started/auto_wizard')
    body     = parse(response.body)
    body.is_a?(Hash) && body['auto_wizard_success'] == true
  rescue Faraday::Error => e
    # Wrapped the way {.verify_setup_done!} wraps its failure, so that a
    # Zammad that never came up reaches every example as a SetupError naming
    # the URL rather than as a bare Faraday exception.
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
# That coupling holds as long as the whole file runs in definition order.
# Under `--only-failures` or `-e 'save'` it does not, and this names the
# cause where the example would otherwise fail on nil.
module LifecycleState
  def established!(record, example)
    return record if record

    raise "this example continues the record built by '#{example}', which did not run in this process. " \
          'These examples share one record and have to run as a whole file, in definition order.'
  end
end
