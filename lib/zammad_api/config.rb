# frozen_string_literal: true

require 'logger'
require_relative 'errors'
require_relative 'version'

module ZammadAPI
  # Immutable, validated client configuration.
  #
  # Credentials are never included in {#inspect} output, so configuration
  # objects are safe to log or attach to exception reports.
  #
  # @example
  #   ZammadAPI::Config.new(url: 'https://zammad.example.com/', http_token: 'secret')
  #
  # @!attribute [r] url
  #   @return [String] base URL, always with a trailing slash
  # @!attribute [r] user
  #   @return [String, nil] login for basic authentication
  # @!attribute [r] password
  #   @return [String, nil] password for basic authentication
  # @!attribute [r] http_token
  #   @return [String, nil] Zammad access token
  # @!attribute [r] oauth2_token
  #   @return [String, nil] OAuth2 bearer token
  # @!attribute [r] user_agent
  #   @return [String] value of the +User-Agent+ request header
  # @!attribute [r] timeout
  #   @return [Numeric] seconds to wait for a response
  # @!attribute [r] open_timeout
  #   @return [Numeric] seconds to wait for the connection
  # @!attribute [r] retries
  #   @return [Integer] retry attempts for idempotent requests
  # @!attribute [r] retry_interval
  #   @return [Numeric] seconds before the first retry, doubling after that
  # @!attribute [r] ssl_verify
  #   @return [Boolean] whether TLS certificates are verified
  # @!attribute [r] proxy
  #   @return [String, nil] proxy URL
  # @!attribute [r] logger
  #   @return [Logger] where debug output goes
  Config = Data.define(
    :url,
    :user,
    :password,
    :http_token,
    :oauth2_token,
    :user_agent,
    :timeout,
    :open_timeout,
    :retries,
    :retry_interval,
    :ssl_verify,
    :proxy,
    :logger
  )

  class Config
    # Seconds to wait for a response before raising {TimeoutError}.
    DEFAULT_TIMEOUT = 60

    # Seconds to wait for the connection to be established.
    DEFAULT_OPEN_TIMEOUT = 10

    # How often an idempotent request is retried on a transient failure.
    DEFAULT_RETRIES = 2

    # Seconds to wait before the first retry; doubles on each attempt.
    DEFAULT_RETRY_INTERVAL = 0.5

    # Attributes whose values must never be rendered.
    REDACTED_ATTRIBUTES = %i[password http_token oauth2_token].freeze

    # Placeholder rendered in place of a credential.
    REDACTION = '[REDACTED]'

    URL_PATTERN = %r{\Ahttps?://}i

    def initialize(
      url:,
      user: nil,
      password: nil,
      http_token: nil,
      oauth2_token: nil,
      user_agent: "zammad_api-ruby/#{ZammadAPI::VERSION}",
      timeout: DEFAULT_TIMEOUT,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      retries: DEFAULT_RETRIES,
      retry_interval: DEFAULT_RETRY_INTERVAL,
      ssl_verify: true,
      proxy: nil,
      logger: nil
    )
      # RBS cannot describe the initializer that Data.define generates, so
      # these keyword arguments are invisible to the type checker.
      # steep:ignore:start
      super(
        url:            normalize_url(url),
        user:           presence(user),
        password:       presence(password),
        http_token:     presence(http_token),
        oauth2_token:   presence(oauth2_token),
        user_agent:     user_agent,
        timeout:        timeout,
        open_timeout:   open_timeout,
        retries:        retries,
        retry_interval: retry_interval,
        ssl_verify:     ssl_verify,
        proxy:          presence(proxy),
        logger:         logger || Logger.new(IO::NULL)
      )
      # steep:ignore:end
      validate_credentials!
      validate_numbers!
    end

    # @return [Symbol] +:http_token+, +:oauth2_token+ or +:basic+
    def authentication_scheme
      return :http_token   if http_token
      return :oauth2_token if oauth2_token

      :basic
    end

    # @return [String] configuration description with credentials redacted
    def inspect
      rendered = to_h.map { |key, value| "#{key}=#{render(key, value)}" }
      "#<data ZammadAPI::Config #{rendered.join(', ')}>"
    end
    alias to_s inspect

    private

    def render(key, value)
      return REDACTION if REDACTED_ATTRIBUTES.include?(key) && value
      # Loggers have verbose default inspect output that would drown out the
      # rest of the configuration.
      return "#<#{value.class}>" if key == :logger

      value.inspect
    end

    def normalize_url(value)
      raise ConfigurationError, 'missing url in config' if presence(value).nil?
      raise ConfigurationError, 'config url needs to start with http:// or https://' if !URL_PATTERN.match?(value)

      # A trailing slash keeps Zammad installations served from a sub-path
      # (e.g. https://example.com/zammad/) working, because request paths are
      # appended relative to this prefix.
      value.end_with?('/') ? value : "#{value}/"
    end

    def validate_credentials!
      return if http_token || oauth2_token

      raise ConfigurationError, 'missing user in config'     if user.nil?
      raise ConfigurationError, 'missing password in config' if password.nil?
    end

    def validate_numbers!
      { timeout: timeout, open_timeout: open_timeout, retry_interval: retry_interval }.each do |name, value|
        raise ConfigurationError, "config #{name} needs to be a positive number" if !value.is_a?(Numeric) || !value.positive?
      end

      raise ConfigurationError, 'config retries needs to be a non-negative integer' if !retries.is_a?(Integer) || retries.negative?
    end

    def presence(value)
      return nil if value.nil?
      return nil if value.respond_to?(:empty?) && value.empty?

      value
    end

    def normalized_string(value)
      value.to_s
    end
  end
end
