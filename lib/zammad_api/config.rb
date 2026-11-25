# frozen_string_literal: true

require 'logger'
require 'uri'

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
  #   @return [Integer] retry attempts for a request that only reads
  # @!attribute [r] retry_interval
  #   @return [Numeric] seconds before the first retry, doubling after that
  #     up to {#timeout}, with up to half of it added as jitter
  # @!attribute [r] ssl_verify
  #   @return [Boolean] whether TLS certificates are verified
  # @!attribute [r] proxy
  #   @return [String, nil] proxy URL
  # @!attribute [r] adapter
  #   @return [Symbol, nil] name of the Faraday adapter, +nil+ for Faraday's default
  # @!attribute [r] middleware
  #   @return [Proc, nil] called with the Faraday connection while it is
  #     being built, after this gem's own middleware
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
    :adapter,
    :middleware,
    :logger
  )

  class Config
    # Seconds to wait for a response.
    DEFAULT_TIMEOUT = 60

    # Seconds to wait for the connection.
    DEFAULT_OPEN_TIMEOUT = 10

    # Retry attempts for a request that only reads.
    DEFAULT_RETRIES = 2

    # Seconds before the first retry.
    DEFAULT_RETRY_INTERVAL = 0.5

    # Value of the +User-Agent+ header unless one is configured.
    DEFAULT_USER_AGENT = "zammad_api-ruby/#{ZammadAPI::VERSION}".freeze

    # What {#inspect} prints in place of a credential.
    REDACTION = '[REDACTED]'

    # The options of each way to authenticate.
    CREDENTIAL_OPTIONS = {
      http_token:   %i[http_token],
      oauth2_token: %i[oauth2_token],
      basic:        %i[user password]
    }.freeze

    # Lays +overrides+ over +options+, dropping the credentials they replace.
    #
    # A configuration authenticates one way, so an override that names one
    # takes the place of every other. The options of its own scheme are kept,
    # so overriding +password:+ alone still pairs it with the +user+ there.
    #
    # @api private
    # @param options [Hash{Symbol => Object}] the options being overridden
    # @param overrides [Hash{Symbol => Object}]
    # @return [Hash{Symbol => Object}]
    def self.merge_options(options, overrides)
      named    = CREDENTIAL_OPTIONS.select { |_, keys| keys.any? { !overrides[it].to_s.strip.empty? } }
      replaced = named.empty? ? [] : CREDENTIAL_OPTIONS.except(*named.keys).values.flatten

      options.except(*replaced).merge(overrides)
    end

    # @param url [String] base URL of the Zammad instance
    # @param user [String, nil] login for basic authentication
    # @param password [String, nil] password for basic authentication
    # @param http_token [String, nil] Zammad access token
    # @param oauth2_token [String, nil] OAuth2 bearer token
    # @param user_agent [String, nil] value of the +User-Agent+ header
    # @param timeout [Numeric] seconds to wait for a response
    # @param open_timeout [Numeric] seconds to wait for the connection
    # @param retries [Integer] retry attempts for a request that only reads
    # @param retry_interval [Numeric] seconds before the first retry
    # @param ssl_verify [Boolean] whether TLS certificates are verified
    # @param proxy [String, nil] proxy URL
    # @param adapter [Symbol, String, nil] name of a Faraday adapter
    # @param middleware [#call, nil] called with the Faraday connection while it is built
    # @param logger [Logger, nil] where debug output goes; discarded by default
    # @raise [ConfigurationError] when the options are incomplete or invalid
    def initialize(
      url: nil,
      user: nil,
      password: nil,
      http_token: nil,
      oauth2_token: nil,
      user_agent: nil,
      timeout: DEFAULT_TIMEOUT,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      retries: DEFAULT_RETRIES,
      retry_interval: DEFAULT_RETRY_INTERVAL,
      ssl_verify: true,
      proxy: nil,
      adapter: nil,
      middleware: nil,
      logger: nil
    )
      # RBS cannot describe the initializer that Data.define generates.
      # steep:ignore:start
      super(
        url:            normalize_url(url),
        user:           present(user),
        password:       present(password),
        http_token:     stripped(http_token),
        oauth2_token:   stripped(oauth2_token),
        user_agent:     stripped(user_agent) || DEFAULT_USER_AGENT,
        timeout:        timeout,
        open_timeout:   open_timeout,
        retries:        retries,
        retry_interval: retry_interval,
        ssl_verify:     ssl_verify,
        proxy:          present(proxy),
        adapter:        present(adapter)&.to_sym,
        middleware:     middleware,
        logger:         logger || Logger.new(IO::NULL)
      )
      # steep:ignore:end

      validate_credentials!
    end

    # @return [Symbol] +:http_token+, +:oauth2_token+ or +:basic+
    def authentication_scheme
      return :http_token   if http_token
      return :oauth2_token if oauth2_token

      :basic
    end

    # Returns a copy with some options changed, re-validated. Naming one way
    # to authenticate replaces the one this configuration had.
    #
    # @param options [Hash] any option this class accepts
    # @return [Config]
    # @raise [ConfigurationError] when the resulting options are invalid
    def with(**options) = self.class.new(**self.class.merge_options(to_h, options))

    # @return [String] configuration description with credentials redacted
    def inspect
      rendered = to_h.map { |key, value| "#{key}=#{render(key, value)}" }
      "#<data ZammadAPI::Config #{rendered.join(', ')}>"
    end
    alias to_s inspect

    # What +pp+, and so a console, prints: {#inspect}, rather than every member.
    #
    # @api private
    # @param printer [PP]
    # @return [void]
    def pretty_print(printer) = printer.text(inspect)

    private

    def render(key, value)
      return value.inspect if value.nil?

      case key
      when :password, :http_token, :oauth2_token then REDACTION
      when :proxy                                then value.to_s.sub(%r{//[^/@]*@}, "//#{REDACTION}@").inspect
      when :logger, :middleware                  then "#<#{value.class}>"
      else value.inspect
      end
    end

    def normalize_url(value)
      raise ConfigurationError, 'missing url in config' if value.to_s.empty?

      uri = URI.parse(value.to_s)
      raise ConfigurationError, 'config url needs to start with http:// or https:// and name a host' if !uri.is_a?(URI::HTTP) || uri.host.to_s.empty?
      raise ConfigurationError, 'config url carries credentials: pass user: and password:, or a token, instead' if uri.userinfo

      value.end_with?('/') ? value : "#{value}/"
    rescue URI::InvalidURIError
      raise ConfigurationError, 'config url is not a valid URL'
    end

    def validate_credentials!
      given = CREDENTIAL_OPTIONS.select { |_, options| options.any? { !public_send(it).nil? } }.keys
      if given.size > 1
        named = given.map { CREDENTIAL_OPTIONS.fetch(it).join(' and ') }.join(', ')
        raise ConfigurationError, "config names more than one way to authenticate (#{named}): pass http_token:, or oauth2_token:, or user: and password:"
      end
      return if http_token || oauth2_token

      raise ConfigurationError, 'missing user in config'     if user.nil?
      raise ConfigurationError, 'missing password in config' if password.nil?
    end

    def present(value) = value.nil? || value.to_s.empty? ? nil : value

    def stripped(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
