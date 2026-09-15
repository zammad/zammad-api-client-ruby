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
  # @!attribute [r] adapter
  #   @return [Symbol, nil] name of the Faraday adapter, +nil+ for Faraday's
  #     default
  # @!attribute [r] middleware
  #   @return [Proc, nil] called with the Faraday connection while it is
  #     being built
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

    # Identifies this gem in the +User-Agent+ header.
    DEFAULT_USER_AGENT = "zammad_api-ruby/#{ZammadAPI::VERSION}".freeze

    SCHEME_PATTERN = %r{\Ahttps?://}i

    # An absolute http(s) URL, authority included. The host is part of the
    # pattern because a bare scheme - +https://+ - passed a scheme-only check
    # and was accepted here, then failed deep inside the adapter on the first
    # request instead of at construction, which is the opposite of the
    # up-front validation the rest of this class exists for.
    URL_PATTERN = %r{\Ahttps?://[^/?\#]+}i

    # Where a URL stops being the part a trailing slash belongs on.
    URL_SUFFIX_PATTERN = /[?\#]/

    # The +user:password@+ part of a URL. A proxy URL carries its credentials
    # inline, so {#inspect} has to blank them while keeping the host visible.
    #
    # Anchored on the last +@+ before the path rather than the first, because
    # a password may carry an unencoded one: +pa@ss+ used to leave +@ss+ in
    # the rendered URL, and a partly redacted credential still reaches every
    # log and exception report the whole one was kept out of.
    #
    # Bounded by +?+ and +#+ as well as +/+, so that it stays inside the
    # authority. Bounded only by the path, it crossed into a query string and
    # read an +@+ there as a credential marker: +https://host?a=b@c+ rendered
    # as +https://[REDACTED]@c+, a host that does not exist - printed in every
    # ConnectionError and TimeoutError message and in {#inspect}, so the
    # operator debugging an outage was shown the wrong instance.
    #
    # The scheme is optional, and matched rather than looked behind, because a
    # proxy is configured without one as often as with: +u:p@proxy:8080+ is
    # the shape an +http_proxy+ style setting is copied out of, and a
    # +://+ lookbehind left that password in {#inspect} in full.
    USERINFO_PATTERN = %r{\A(?<scheme>[a-z][a-z0-9+.-]*://)?(?<userinfo>[^/?\#]+)(?=@)}i

    # Replacement that keeps the scheme and drops the credential.
    USERINFO_REPLACEMENT = "\\k<scheme>#{REDACTION}".freeze

    def initialize(
      url:,
      user: nil,
      password: nil,
      http_token: nil,
      oauth2_token: nil,
      user_agent: DEFAULT_USER_AGENT,
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
      # RBS cannot describe the initializer that Data.define generates, so
      # these keyword arguments are invisible to the type checker.
      # steep:ignore:start
      super(
        url:            immutable(normalize_url(url)),
        user:           immutable(presence(user)),
        password:       immutable(presence(password)),
        http_token:     immutable(presence(http_token)),
        oauth2_token:   immutable(presence(oauth2_token)),
        user_agent:     immutable(presence(user_agent) || DEFAULT_USER_AGENT),
        timeout:        timeout,
        open_timeout:   open_timeout,
        retries:        retries,
        retry_interval: retry_interval,
        ssl_verify:     ssl_verify,
        proxy:          immutable(normalize_proxy(proxy)),
        adapter:        normalize_adapter(adapter),
        middleware:     middleware,
        logger:         logger || Logger.new(IO::NULL)
      )
      # steep:ignore:end
      validate_credentials!
      validate_numbers!
      validate_user_agent!
      validate_ssl_verify!
      validate_middleware!
      validate_logger!
    end

    # The instance URL, with any inline credentials blanked.
    #
    # A URL may carry basic-auth credentials in its userinfo, and 1.x users
    # who put them there rather than in +user:+ and +password:+ still do. The
    # host has to stay readable for the URL to be worth printing, so the
    # credentials are replaced rather than the whole value.
    #
    # @return [String]
    def redacted_url = redacted(url)

    # Blanks the credentials in any URL this configuration holds.
    #
    # Public because {Transport} has to scrub the values it configured out of
    # an error message raised from deep inside Faraday or URI, which quotes
    # the proxy URL it rejected - credentials and all.
    #
    # @api private
    # @param value [String] a URL that may carry inline credentials
    # @return [String] the same URL with the credentials blanked
    def redacted(value) = redact_userinfo(value)

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

    # @param value [String] a URL that may carry inline credentials
    # @return [String] the same URL with the credentials blanked
    def redact_userinfo(value) = value.sub(USERINFO_PATTERN, USERINFO_REPLACEMENT)

    def render(key, value)
      return REDACTION if REDACTED_ATTRIBUTES.include?(key) && value
      # Loggers and procs have verbose default inspect output that would drown
      # out the rest of the configuration.
      return "#<#{value.class}>" if key == :logger
      return "#<#{value.class}>" if key == :middleware && value
      return redacted_url.inspect if key == :url
      return redact_userinfo(value).inspect if key == :proxy && value

      value.inspect
    end

    # The type check comes before the pattern, because every check after it
    # is a String method. A URI is the plausible mistake here - it is what
    # `URI(...)` hands back and it prints as the URL - and it used to reach
    # `end_with?` and die there as a NoMethodError, past the ConfigurationError
    # a caller had wrapped the constructor in.
    def normalize_url(value)
      raise ConfigurationError, 'missing url in config' if presence(value).nil?
      raise ConfigurationError, "config url needs to be a string, got #{value.class}" if !value.is_a?(String)
      raise ConfigurationError, 'config url needs to start with http:// or https://' if !SCHEME_PATTERN.match?(value)
      raise ConfigurationError, "config url needs a host after the scheme, got #{value.inspect}" if !URL_PATTERN.match?(value)

      # A trailing slash keeps Zammad installations served from a sub-path
      # (e.g. https://example.com/zammad/) working, because request paths are
      # appended relative to this prefix.
      #
      # Onto the path, not onto the end of the string. Appended blindly it
      # landed behind a query string or fragment, so a url of
      # `https://host/zammad?a=1` became `https://host/zammad?a=1/` - the base
      # every request is resolved against, and the value {#redacted_url}
      # prints in every ConnectionError and TimeoutError message.
      path, separator, rest = value.partition(URL_SUFFIX_PATTERN)
      path.end_with?('/') ? value : "#{path}/#{separator}#{rest}"
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

    # Not just a default: `user_agent: nil` reached Faraday as a nil header,
    # and Faraday filled in its own, so the gem stopped identifying itself in
    # the instance log an operator greps to find its requests - silently, and
    # on every request.
    def validate_user_agent!
      return if user_agent.is_a?(String)

      raise ConfigurationError, 'config user_agent needs to be a string'
    end

    # A proxy is the second string here that may carry credentials, and the
    # only other one rendered rather than replaced wholesale. Unchecked, a
    # URI - what `URI(...)` hands back, and what prints as the URL - was
    # accepted here and reached String#sub inside {#inspect}, so the object
    # this class documents as safe to log raised NoMethodError at exactly the
    # moment something tried to log it. The same mistake {#normalize_url}
    # already refuses for the instance URL.
    def normalize_proxy(value)
      return nil if presence(value).nil?
      raise ConfigurationError, "config proxy needs to be a string, got #{value.class}" if !value.is_a?(String)

      value
    end

    # `adapter&.to_sym` accepted anything that answered to_sym and died with
    # a bare NoMethodError on anything that did not - `adapter: 1` and
    # `adapter: true` both escaped the ConfigurationError that building a
    # client is documented to need, from inside the constructor, before any
    # of the validators below ran.
    def normalize_adapter(value)
      return nil if presence(value).nil?
      raise ConfigurationError, "config adapter needs to be a symbol or a string, got #{value.class}" if !value.is_a?(Symbol) && !value.is_a?(String)

      value.to_sym
    end

    # The one option that fails open. Every other value here is checked up
    # front, while ssl_verify was passed to Faraday as it arrived: read from
    # an environment variable, `ssl_verify: 'false'` is the string "false",
    # which is truthy, so the setting a caller believed they had turned off
    # was silently still on. That direction is the safe one, which is why it
    # went unnoticed - `ssl_verify: 'no'` disables nothing either way, but a
    # caller who cannot tell which of their settings took effect has no way
    # to find out.
    def validate_ssl_verify!
      return if [true, false].include?(ssl_verify)

      raise ConfigurationError, "config ssl_verify needs to be true or false, got #{ssl_verify.inspect}"
    end

    def validate_middleware!
      return if middleware.nil? || middleware.respond_to?(:call)

      raise ConfigurationError, 'config middleware needs to respond to call'
    end

    # In 1.x this option was a flag, so `logger: true` is a plausible thing to
    # carry over. Without this it would be accepted here and raise NoMethodError
    # at the first request instead.
    def validate_logger!
      return if logger.respond_to?(:debug)

      raise ConfigurationError, 'config logger needs to respond to debug'
    end

    def presence(value)
      return nil if value.nil?
      return nil if value.respond_to?(:empty?) && value.empty?

      value
    end

    # Ruby leaves the members of a Data object mutable, so a caller-supplied
    # String would otherwise stay writable through the config - and shared
    # with the caller's own variable. Freezing a copy keeps a Config, and any
    # Transport built from one, genuinely immutable.
    #
    # This deliberately copies rather than using String#-@: interning would
    # keep a credential in the global fstring table for the life of the
    # process, well past the config that held it.
    def immutable(value)
      value.is_a?(String) ? value.dup.freeze : value
    end
  end
end
