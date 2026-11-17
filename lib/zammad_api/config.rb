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

    # How often a request that only reads is retried on a transient failure.
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

    # The scheme of a URL, where it has one. A proxy is configured without
    # one as often as with - +u:p@proxy:8080+ is the shape an +http_proxy+
    # style setting is copied out of - so the redaction below cannot assume
    # it.
    URL_SCHEME_PATTERN = %r{\A[a-z][a-z0-9+.-]*://}i

    # What RFC 3986 calls the authority of a URL: everything up to the first
    # +/+, +?+ or +#+ after the scheme.
    URL_AUTHORITY_PATTERN = %r{\A[^/?\#]*}

    # The options each authentication scheme is made of.
    CREDENTIAL_OPTIONS = {
      http_token:   %i[http_token],
      oauth2_token: %i[oauth2_token],
      basic:        %i[user password]
    }.freeze

    # Lays +overrides+ over +options+, dropping the credentials they replace.
    #
    # A credential is one option out of several that are read in a fixed
    # order - see {#authentication_scheme} - so a plain merge left the old
    # scheme in charge: with +ZAMMAD_TOKEN+ set,
    # +Client.from_env(user: 'u', password: 'p')+ still sent the
    # environment's token, and +client.with(oauth2_token: 'x')+ on a token
    # client went on acting as the account the token belonged to. Neither
    # raised, and both read as if they had switched identity.
    #
    # An override that names a scheme therefore takes the place of every
    # other scheme. The options of its own scheme are kept, so overriding
    # +password:+ alone still pairs it with the +user+ already there.
    #
    # @api private
    # @param options [Hash{Symbol => Object}] the options being overridden
    # @param overrides [Hash{Symbol => Object}]
    # @return [Hash{Symbol => Object}]
    def self.merge_options(options, overrides)
      named    = CREDENTIAL_OPTIONS.select { |_, keys| keys.any? { !overrides[it].to_s.empty? } }
      replaced = named.empty? ? [] : CREDENTIAL_OPTIONS.except(*named.keys).values.flatten

      options.except(*replaced).merge(overrides)
    end

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
    # A URL that carries credentials is refused when the configuration is
    # built - see {#normalize_url} - but only where it can be read as a URL
    # at all. One that cannot, such as a password with an unencoded +#+ in
    # it, is still held here until building the connection rejects it, and
    # this is what that error and {#inspect} print in the meantime. The host
    # has to stay readable for the URL to be worth printing, so the
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

    # Returns a copy with some options changed, re-validated.
    #
    # Through {.merge_options} rather than Data's own merge, so that naming
    # one authentication scheme replaces the one this configuration had.
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

    # What +pp+ prints, which is what IRB and the Rails console show for a
    # value typed at the prompt.
    #
    # +pp+ does not go through {#inspect} for a Data object: it has a printer
    # of its own that renders the members directly. So +client.config+ in a
    # console, or +pp config+ in a script, printed the token, the password
    # and the credentials of a proxy in full - from the class documented as
    # safe to log, and through the one route most likely to be looked at.
    #
    # @api private
    # @param printer [PP]
    # @return [void]
    def pretty_print(printer) = printer.text(inspect)

    private

    # Blanks the +user:password@+ part of a URL, keeping the host visible.
    #
    # Everything up to the last +@+ goes, rather than up to the first: a
    # password may carry an unencoded one, and +pa@ss+ used to leave +@ss+ in
    # the rendered URL.
    #
    # Which +@+ is the last one depends on whether a password can be there at
    # all. Without a colon in the authority there is none, so the search
    # stays inside the authority and an +@+ in a path, a query string or a
    # fragment is left alone: +https://host?a=b@c+ used to render as
    # +https://[REDACTED]@c+, a host that does not exist, in every
    # ConnectionError message.
    #
    # With a colon, the search runs to the end of the value. A password is
    # not obliged to be URL-safe, and one carrying +/+, +?+ or +#+ ends the
    # authority early as far as the syntax goes: +http://user:p#ss@proxy+ has
    # the authority +user:p+, which holds no +@+, so a search bounded by it
    # found nothing to blank and printed the password - in {#inspect}, and in
    # the ConfigurationError that quotes a proxy URL the HTTP stack rejected.
    # The cost is a URL with a port and an +@+ further on, such as
    # +https://host:8443/a@b+, which renders with its host blanked. A colon
    # cannot tell a port from a password, and of the two mistakes that is the
    # one that leaks nothing.
    #
    # @param value [String] a URL that may carry inline credentials
    # @return [String] the same URL with the credentials blanked
    def redact_userinfo(value)
      scheme    = value[URL_SCHEME_PATTERN].to_s
      rest      = value.delete_prefix(scheme)
      authority = rest[URL_AUTHORITY_PATTERN].to_s
      boundary  = authority.include?(':') ? rest.rindex('@') : authority.rindex('@')
      return value if boundary.nil?

      "#{scheme}#{REDACTION}#{rest[boundary..]}"
    end

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
      raise ConfigurationError, inline_credentials_message(value) if inline_credentials?(value)

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

    # Whether the URL carries a +user:password@+ of its own.
    #
    # Asked of URI, because that is the parser Faraday reads the URL with:
    # whatever it finds there, Faraday turns into a Basic +Authorization+
    # header on the connection, and its authorization middleware then leaves
    # a header that is already set alone. So a URL with credentials silently
    # replaced the scheme this class validated - an access token configured
    # beside it was never sent, while {Client#inspect} went on reporting
    # +auth=http_token+.
    #
    # A URL that URI cannot read is left for the connection to reject, which
    # it does before any request is made.
    def inline_credentials?(value)
      !URI.parse(value).userinfo.nil?
    rescue URI::InvalidURIError
      false
    end

    def inline_credentials_message(value)
      "config url carries credentials of its own (#{redact_userinfo(value)}), which would be sent as basic authentication " \
        'in place of the ones this configuration names. Leave them out of the url and pass user: and password:, ' \
        'or http_token: or oauth2_token:, instead.'
    end

    def validate_credentials!
      return if http_token || oauth2_token

      raise ConfigurationError, 'missing user in config'     if user.nil?
      raise ConfigurationError, 'missing password in config' if password.nil?
    end

    # Numeric is not the whole test. Complex is one and answers neither
    # `positive?` nor `>`, so `timeout: Complex(1, 2)` left a NoMethodError
    # where every other rejected option raises ConfigurationError - the same
    # escape normalize_adapter, normalize_proxy and validate_logger! were each
    # written to close.
    def positive_number?(value) = value.is_a?(Numeric) && value.respond_to?(:positive?) && value.positive?

    def validate_numbers!
      { timeout: timeout, open_timeout: open_timeout, retry_interval: retry_interval }.each do |name, value|
        raise ConfigurationError, "config #{name} needs to be a positive number" if !positive_number?(value)
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
