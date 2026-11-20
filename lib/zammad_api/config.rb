# frozen_string_literal: true

require 'json'
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
  #     up to {#timeout}. A +Retry-After+ header takes its place where it
  #     asks for longer, up to {#timeout} as well. Up to half of this is
  #     added to a wait that is not a +Retry-After+, as jitter, so one can be
  #     that much longer than {#timeout}.
  # @!attribute [r] ssl_verify
  #   @return [Boolean] whether TLS certificates are verified
  # @!attribute [r] proxy
  #   @return [String, nil] proxy URL
  # @!attribute [r] adapter
  #   @return [Symbol, nil] name of the Faraday adapter, +nil+ for Faraday's
  #     default or for one the +middleware+ callable sets
  # @!attribute [r] middleware
  #   @return [Proc, nil] called with the Faraday connection while it is
  #     being built. An adapter it sets is the one used, which is how an
  #     adapter is given arguments; one named in +adapter+ as well is
  #     refused when the connection is built
  # @!attribute [r] logger
  #   @return [Logger] where debug output goes. Any object will do whose
  #     +debug+ can be called with a block and no argument, which is how
  #     each line is handed over
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

    # The longest wait a configuration takes, in seconds: a little over
    # three years, and the longest one every platform takes. macOS refuses a
    # wait on a socket that is one second longer, and what came of it was a
    # ConnectionError calling the instance unreachable.
    MAX_SECONDS = 100_000_000

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
    # A configuration authenticates one way, so an override that names
    # another has to take the old one's place, not sit beside it. A plain
    # merge left both, and the old scheme in charge: with +ZAMMAD_TOKEN+ set,
    # +Client.from_env(user: 'u', password: 'p')+ still sent the
    # environment's token, and +client.with(oauth2_token: 'x')+ on a token
    # client went on acting as the account the token belonged to. Neither
    # raised, and both read as if they had switched identity. Two schemes
    # side by side are refused outright now, which is what makes dropping
    # the old one here necessary rather than merely right.
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

    # `url:` has a default so that leaving it out is answered by
    # {#normalize_url}, with the ConfigurationError that building a client is
    # documented to raise and that 1.x raised. As a required keyword it was
    # Ruby that answered, with `ArgumentError: missing keyword: :url`, past
    # the rescue a caller had written for an incomplete configuration.
    def initialize(
      url: nil,
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
        user:           immutable(non_empty(user)),
        password:       immutable(non_empty(password)),
        http_token:     immutable(non_empty(http_token)),
        oauth2_token:   immutable(non_empty(oauth2_token)),
        user_agent:     immutable(non_empty(user_agent) || DEFAULT_USER_AGENT),
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
      validate_header_options!
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

    # The one way this configuration authenticates. There is never more than
    # one to choose between: see {#validate_credentials!}.
    #
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

    # The configuration for a JSON encoder: every option, with what
    # {#inspect} blanks blanked.
    #
    # ActiveSupport gives a Data an +as_json+ that is its members as they
    # are, and builds +to_json+ on it. So in a Rails app +config.to_json+
    # wrote the token, the password and the credentials of a proxy in full,
    # and so did a log line or an error report that serialized something
    # holding the configuration - the third way out of the class documented
    # as safe to log, after {#inspect} and +pp+, and the one a structured
    # logger takes.
    #
    # @return [Hash{Symbol => Object}]
    def as_json(*) = to_h.to_h { |key, value| [key, placeholder(key, value) || printable(key, value)] }

    # Without this, +JSON.generate+ would write the configuration as one
    # String, its {#to_s}, and ActiveSupport would not come by {#as_json}
    # where +to_json+ is what is called.
    #
    # @param state [JSON::State, nil] passed by +JSON.generate+
    # @return [String] {#as_json} as a JSON object
    def to_json(state = nil) = as_json.to_json(state)

    # What Psych writes for a configuration: {#as_json}, as a plain mapping
    # of what its JSON reads back as.
    #
    # Psych asks none of the above. It writes the members of a Data as
    # they are, so +config.to_yaml+ held the token, the password and the
    # credentials of a proxy in full - the fourth way out of the class
    # documented as safe to log, and the one Rails' +debug+ view helper and
    # a Delayed::Job handler take.
    #
    # No tag is written, so the mapping loads as the Hash it is and not as
    # a configuration with placeholders where its credentials were. And it
    # goes through the JSON, so that nothing in it is an object Psych would
    # write by its instance variables in turn.
    #
    # @api private
    # @param coder [Psych::Coder]
    # @return [void]
    def encode_with(coder) = coder.represent_object(nil, JSON.parse(to_json))

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
    # An empty authority is searched the same way, for the same reason and
    # at no cost: there is no host in it to blank by mistake. It is what a
    # slash too many leaves, or the slashes without the scheme - the
    # authority ends at the first slash, so +//user:secret@proxy:8080+ and
    # +https:///user:secret@host/+ have none, with no colon and no +@+ in it,
    # and were printed as they stood: the proxy by {#inspect}, and the url
    # by the ConfigurationError that refuses a url without a host.
    #
    # @param value [String] a URL that may carry inline credentials
    # @return [String] the same URL with the credentials blanked
    def redact_userinfo(value)
      scheme    = value[URL_SCHEME_PATTERN].to_s
      rest      = value.delete_prefix(scheme)
      authority = rest[URL_AUTHORITY_PATTERN].to_s
      boundary  = authority.empty? || authority.include?(':') ? rest.rindex('@') : authority.rindex('@')
      return value if boundary.nil?

      "#{scheme}#{REDACTION}#{rest[boundary..]}"
    end

    # One option as {#inspect} prints it. What stands in for a value is
    # printed bare, and a value as it inspects.
    def render(key, value) = placeholder(key, value) || printable(key, value).inspect

    # What is shown in place of an option that is not shown itself, where it
    # is one of those. One rule for {#inspect} and {#as_json}: a second
    # copy of which options are credentials is the copy that misses the
    # next one.
    #
    # @return [String, nil]
    def placeholder(key, value)
      return REDACTION if REDACTED_ATTRIBUTES.include?(key) && value

      # Loggers and procs have verbose default inspect output that would drown
      # out the rest of the configuration, and an encoder walks into whatever
      # they hold.
      "#<#{value.class}>" if key == :logger || (key == :middleware && value)
    end

    # An option that is shown, as it may be: a URL without the credentials
    # it carries.
    def printable(key, value)
      return redacted_url if key == :url
      return redact_userinfo(value) if key == :proxy && value

      value
    end

    # The type check comes before the pattern, because every check after it
    # is a String method. A URI is the plausible mistake here - it is what
    # `URI(...)` hands back and it prints as the URL - and it used to reach
    # `end_with?` and die there as a NoMethodError, past the ConfigurationError
    # a caller had wrapped the constructor in.
    def normalize_url(value)
      raise ConfigurationError, 'missing url in config' if non_empty(value).nil?
      raise ConfigurationError, "config url needs to be a string, got #{value.class}" if !value.is_a?(String)
      raise ConfigurationError, 'config url needs to start with http:// or https://' if !SCHEME_PATTERN.match?(value)
      # Quoted through the redaction: what follows the scheme here is not a
      # host, and may be the credentials of a url with a slash too many.
      raise ConfigurationError, "config url needs a host after the scheme, got #{redact_userinfo(value).inspect}" if !URL_PATTERN.match?(value) || hostless?(value)
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

    # Whether what follows the scheme names no host, though something
    # stands there: a port alone, as in +http://:3000/+.
    #
    # It is what `"http://#{ENV['ZAMMAD_HOST']}:3000/"` comes to where the
    # variable is not set, and {URL_PATTERN} asks only for a character that
    # ends no authority. Net::HTTP connects to localhost for an empty host,
    # so the client was built and then sent every request, with the token
    # in its header, to whatever listens on that port of the machine it
    # runs on.
    #
    # Asked of URI for the reason {#inline_credentials?} is, and a URL that
    # URI cannot read is left to the connection for the same one.
    def hostless?(value)
      URI.parse(value).host.to_s.empty?
    rescue URI::InvalidURIError
      false
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

    # One way to authenticate, and only one.
    #
    # Several used to be accepted together, and {#authentication_scheme}
    # picked the first of them in a fixed order without a word. That is what
    # let an override leave the old credential in charge - a token beside a
    # user and password it was meant to replace - and it is the same mistake
    # wherever it comes from: a client that holds two identities sends one of
    # them, and which one is not something the call site shows. Refused here,
    # a configuration says how it authenticates by construction, and the
    # merges that build one - {.merge_options} - have to drop what an
    # override replaces rather than keep it beside the new value.
    #
    # Half of a scheme counts as naming it, so a token beside a +user+ that
    # has no password is refused as two schemes rather than passed as one.
    def validate_credentials!
      given = CREDENTIAL_OPTIONS.select { |_, options| options.any? { !public_send(it).nil? } }.keys
      raise ConfigurationError, multiple_credentials_message(given) if given.size > 1
      return if http_token || oauth2_token

      raise ConfigurationError, 'missing user in config'     if user.nil?
      raise ConfigurationError, 'missing password in config' if password.nil?
    end

    def too_long_message(name, value)
      "config #{name} needs to be at most #{MAX_SECONDS} seconds, got #{value}. No value stands for no #{name == :retry_interval ? 'limit' : 'timeout'}: " \
        'pass the longest wait that is acceptable.'
    end

    def multiple_credentials_message(schemes)
      named = schemes.map { CREDENTIAL_OPTIONS.fetch(it).join(' and ') }.join(', ')

      "config names more than one way to authenticate (#{named}), and a request can carry only one. " \
        'Pass http_token:, or oauth2_token:, or user: and password:, and leave the others out.'
    end

    # Numeric is not the whole test. Complex is one and answers neither
    # `positive?` nor `>`, so `timeout: Complex(1, 2)` left a NoMethodError
    # where every other rejected option raises ConfigurationError - the same
    # escape normalize_adapter, normalize_proxy and validate_logger! were each
    # written to close.
    def positive_number?(value) = value.is_a?(Numeric) && value.respond_to?(:positive?) && value.positive?

    # A number has to be one the HTTP stack can wait for as well, and that
    # is not every positive one. `timeout: Float::INFINITY`, the natural way
    # to ask for no timeout, which is what 1.x had, was accepted, and every
    # request then raised a bare RangeError from inside Net::HTTP, as it did
    # for a figure past what a C long holds. An infinite +retry_interval+
    # raised the same from the sleep before the first retry.
    def validate_numbers!
      { timeout: timeout, open_timeout: open_timeout, retry_interval: retry_interval }.each do |name, value|
        raise ConfigurationError, "config #{name} needs to be a positive number" if !positive_number?(value)
        raise ConfigurationError, too_long_message(name, value) if value > MAX_SECONDS
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

    # The options that are sent as a header: the two tokens in
    # +Authorization+, and the user agent.
    HEADER_OPTIONS = %i[http_token oauth2_token user_agent].freeze
    private_constant :HEADER_OPTIONS

    # A line break inside one of these was taken here and refused by
    # Net::HTTP at the first request, with the value in the message: see
    # {Transport.line_break?}. Refused here instead, without the value. A
    # user and password are not checked: basic authentication sends them
    # Base64-encoded, which carries a line break like anything else.
    def validate_header_options!
      HEADER_OPTIONS.each do |name|
        value = public_send(name)
        next if !value.is_a?(String) || !Transport.line_break?(header_text(name, value))

        raise ConfigurationError, "config #{name} holds a line break, which a header cannot carry: #{Transport::LINE_BREAK_ADVICE}"
      end
    end

    # The option as text whose bytes are the ones a header carries: see
    # {Transport.wire_text}. Text that cannot be converted cannot be shown
    # to hold no line break, and was passed as holding none. Refused
    # without the error underneath as its cause, which quotes the bytes it
    # stopped at.
    def header_text(name, value)
      Transport.wire_text(value, "config #{name}")
    rescue ArgumentError => e
      raise ConfigurationError, e.message, cause: nil
    end

    # A proxy is the second string here that may carry credentials, and the
    # only other one rendered rather than replaced wholesale. Unchecked, a
    # URI - what `URI(...)` hands back, and what prints as the URL - was
    # accepted here and reached String#sub inside {#inspect}, so the object
    # this class documents as safe to log raised NoMethodError at exactly the
    # moment something tried to log it. The same mistake {#normalize_url}
    # already refuses for the instance URL.
    def normalize_proxy(value)
      return nil if non_empty(value).nil?
      raise ConfigurationError, "config proxy needs to be a string, got #{value.class}" if !value.is_a?(String)

      value
    end

    # `adapter&.to_sym` accepted anything that answered to_sym and died with
    # a bare NoMethodError on anything that did not - `adapter: 1` and
    # `adapter: true` both escaped the ConfigurationError that building a
    # client is documented to need, from inside the constructor, before any
    # of the validators below ran.
    def normalize_adapter(value)
      return nil if non_empty(value).nil?
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
    #
    # Answering `debug` is not the whole of it. The transport calls it the
    # way a Logger is called for a line that costs something to build, with
    # a block and no argument, so a logger written as `def debug(message)`
    # was accepted here and raised a bare ArgumentError at every request.
    def validate_logger!
      raise ConfigurationError, 'config logger needs to respond to debug' if !logger.respond_to?(:debug)
      return if !debug_needs_argument?

      raise ConfigurationError, 'config logger needs a debug that can be called with a block and no argument, as Logger#debug is: ' \
                                'this one requires an argument'
    end

    # A logger that answers `respond_to?` for a method it does not have -
    # one that forwards through `method_missing` and says so nowhere else -
    # cannot be asked, and is taken at its word.
    def debug_needs_argument?
      logger.method(:debug).parameters.any? { |kind, _| %i[req keyreq].include?(kind) }
    rescue NameError
      false
    end

    # Not called `presence`: that is the name of a public method ActiveSupport
    # gives every object, and a private one here answered in its place, so
    # `config.presence` raised NoMethodError in a Rails app.
    def non_empty(value)
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
