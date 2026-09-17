# frozen_string_literal: true

require 'faraday'
require 'faraday/retry'
require 'json'
require 'openssl'
require 'socket'
require 'timeout'

require_relative 'duplicate_keys'
require_relative 'errors'
require_relative 'response'

module ZammadAPI
  # Performs the HTTP requests against a Zammad instance.
  #
  # Instances are immutable once built: {#with_on_behalf_of} returns a copy
  # rather than mutating shared state, which makes a single transport safe to
  # use from several threads.
  #
  # @api private
  class Transport
    # The verb shorthands, defined once for the two transports that answer
    # them.
    #
    # {Test::Transport} stands in for this class precisely so that the code
    # under test cannot tell them apart, and it carried its own copy of this
    # loop - so a fifth verb added here would have left the stand-in unable to
    # answer one the real transport had. The same argument as
    # {Transport.relative_path} and {Resources::Base.member_path}: a rule kept
    # in two places is one that gets changed in one of them.
    #
    # @api private
    module Verbs
      # @!method get(path, operation:, query: nil, headers: nil, resource_class: nil)
      # @!method post(path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
      # @!method put(path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
      # @!method delete(path, operation:, query: nil, headers: nil, resource_class: nil)
      # @return [Response]
      %i[get post put delete].each do |verb|
        define_method(verb) do |path, **options|
          request(verb, path, **options) # steep:ignore NoMethod
        end
      end
    end

    include Verbs

    # HTTP methods that Zammad handles idempotently and that are therefore
    # safe to retry. POST is excluded on purpose - retrying it could create
    # duplicate tickets or users.
    RETRIABLE_METHODS = %i[get put delete head options].freeze

    # Transient statuses worth retrying.
    RETRIABLE_STATUSES = [429, 500, 502, 503, 504].freeze

    # Socket failures that mean the request ran out of time. Most adapters
    # wrap these into a Faraday error, but not all do, and this gem lets a
    # caller choose the adapter.
    #
    # `timeout` and `socket` are required above for this list and the next
    # one. Both constants used to resolve only because `require 'faraday'`
    # reaches net/http, which loads them - so the day Faraday stops eagerly
    # loading its default adapter, or a caller picks a slimmer one, this class
    # body raises NameError and `require 'zammad_api'` fails before a single
    # request. The Steepfile has declared both libraries all along.
    TIMEOUT_ERRORS = [Errno::ETIMEDOUT, Timeout::Error].freeze

    # Socket failures that mean the instance could not be reached. Listed
    # rather than caught as SystemCallError, so that an unrelated Errno - a
    # logger writing to a full disk, say - is not relabelled as a network
    # problem.
    CONNECTION_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::EPIPE,
      SocketError
    ].freeze

    # TLS failures, for the same reason the socket errors above are listed:
    # most adapters wrap one into a Faraday::SSLError, but this gem lets a
    # caller choose the adapter and not every adapter does. Unlisted, a
    # certificate mismatch through such an adapter left `request` raw, past
    # the `rescue ZammadAPI::TransportError` a caller had written - the one
    # thing the rescue clauses there exist to prevent.
    #
    # Not in {RETRIABLE_EXCEPTIONS}: a rejected certificate is a fact about
    # the instance, not a transient failure, and retrying it only delays the
    # error by the backoff.
    SSL_ERRORS = [OpenSSL::SSL::SSLError].freeze

    # Failures worth retrying. Faraday::RetriableResponse is how the retry
    # middleware signals a retriable status internally and must stay in this
    # list, otherwise it escapes as an unhandled Faraday error.
    #
    # Composed from the two lists above rather than repeating them. Listed
    # by hand, CONNECTION_ERRORS was left out: a transient ECONNRESET through
    # an adapter that wraps it was retried as a Faraday::ConnectionFailed,
    # while the same failure through an adapter that does not raised on the
    # first attempt - so how often a request was retried depended on which
    # adapter a caller picked, and `request` already documents these as
    # failures this class expects to see. The retry middleware still only
    # retries RETRIABLE_METHODS, so a POST is not repeated.
    RETRIABLE_EXCEPTIONS = [
      Faraday::RetriableResponse,
      Faraday::ConnectionFailed,
      Faraday::TimeoutError,
      *TIMEOUT_ERRORS,
      *CONNECTION_ERRORS
    ].freeze

    # Substrings that mark a request payload key as carrying a credential.
    # Matching on a substring rather than the whole key covers the variants
    # Zammad and OAuth actually send - password_confirm, access_token,
    # refresh_token, client_secret - which an exact-match list silently let
    # through to the log.
    #
    # The same argument reaches further than the first version of this list
    # took it. `password` alone wrote `passwd` and `pwd` out in full, and
    # `private_key` covered exactly one of the key spellings, so `api_key`
    # and a bare `key` went to the log intact. `key` is matched as a word
    # rather than as a substring, so `ssh_key` and `key` are covered while
    # `keyboard` and `monkey_id` are not; `apikey` is spelled out because
    # nothing separates the word there.
    SENSITIVE_KEY_PATTERN = /password|passwd|pwd|token|secret|credential|api_?key|(?<![a-z])keys?(?![a-z])/i

    REDACTED = '[REDACTED]'

    # Characters RFC 3986 leaves unreserved. Everything else is percent-encoded
    # before it goes into a path segment.
    UNRESERVED_IN_PATH = /[^A-Za-z0-9\-._~]/

    # Path segments that name a position rather than a record. Built entirely
    # from unreserved characters, so the encoding above carries them through
    # untouched.
    DOT_SEGMENTS = ['.', '..'].freeze

    # @return [Config]
    attr_reader :config

    # @return [String, nil] login of the user requests are performed for,
    #   already stringified the way the +From+ header carries it
    attr_reader :on_behalf_of

    # The query parameters a request actually carries.
    #
    # Zammad expects scalar values; booleans and integers are stringified so
    # that Faraday does not encode them as unexpected types.
    #
    # A nil used to be dropped here, which turned `where(owner_id: nil)` - an
    # entirely reasonable way to write "unassigned" - into an unfiltered index
    # answering with every ticket. Wrong results, no error, nothing to see from
    # the outside. There is no query string that means "this field is null", so
    # saying so is the only answer that can be acted on.
    #
    # Public because {Test} records what a test's client sent, and a stand-in
    # whose recorded values disagree with the wire makes green tests mean less
    # than they appear to.
    #
    # Two spellings of one parameter are refused rather than merged. Keys are
    # stringified here, so `{state_id: 1, 'state_id' => 2}` used to collapse
    # into one parameter and send whichever Hash insertion order put last,
    # dropping the other value without a word - the same silent-wrong-result
    # shape as the dropped nil above, and the reason {Collection#where}
    # normalises its keys before they ever reach here.
    #
    # @api private
    # @param query [Hash]
    # @return [Hash{String => String, Array<String>, Hash}]
    # @raise [ArgumentError] for a nil value, or for two keys that name the
    #   same parameter, either of them at any depth
    def self.stringify_query(query) = stringify_query_hash(query, nil)

    # Stringifies one level of a query, at whatever depth it sits.
    #
    # The duplicate check lives here rather than at the top level alone,
    # because `condition` - which the search endpoints read, and which
    # {ResourceProxy::SEARCH_QUERY_KEYS} lists so that {Collection#where}
    # accepts it - is a Hash, and two spellings inside it collapsed exactly
    # the way two spellings at the top level did. The nil check below has been
    # at every depth all along; this is the same kind of rule.
    #
    # The key each name was first seen as is kept, so the message can print
    # both spellings. Naming only the second left the reader to guess the
    # first, which in a query assembled across several merges is the whole of
    # the debugging.
    #
    # @api private
    # @param hash [Hash]
    # @param prefix [String, nil] the parameter path this Hash sits at
    # @return [Hash{String => String, Array, Hash}]
    def self.stringify_query_hash(hash, prefix)
      DuplicateKeys
        .normalize(hash, prefix: prefix, &:to_s)
        .to_h { |name, value| [name, stringify_query_value(prefix ? "#{prefix}[#{name}]" : name, value)] }
    end

    # Stringifies the scalars and leaves the structure to Faraday.
    #
    # A nested value used to be rendered with to_s, so the `condition` that
    # Zammad's search endpoints read - and that {ResourceProxy::SEARCH_QUERY_KEYS}
    # lists, so {Collection#where} accepts it - went on the wire as a Ruby
    # inspect string. Zammad could not parse that, dropped the parameter, and
    # answered with an unnarrowed search that nothing marked as unnarrowed.
    # Faraday's default encoder renders a Hash as
    # `condition[ticket.state_id][operator]=is`, which is the shape Rails reads
    # back, so the structure is handed over intact.
    #
    # @api private
    # @param key [String] the parameter path, for the error message
    # @param value [Object]
    # @return [String, Array, Hash]
    # @raise [ArgumentError] for a nil value
    def self.stringify_query_value(key, value)
      case value
      when nil   then raise ArgumentError, "query parameter #{key} is nil, and Zammad has no way to read that: pass a value, or leave the parameter out"
      when Hash  then stringify_query_hash(value, key)
      when Array then value.each_with_index.map { |inner, index| stringify_query_value("#{key}[#{index}]", inner) }
      else value.to_s
      end
    end

    # Header names this class sets from the configuration, and will not take
    # from a caller.
    #
    # +Authorization+ is built from the credentials {Config} validated, and
    # +From+ is what {Client#on_behalf_of} means. Faraday's authorization
    # middleware leaves a header that is already set alone, so a raw request
    # carrying one of these would have replaced the client's own - quietly,
    # and while {Client#inspect} went on reporting the authentication scheme
    # it was built with. Naming the option that does mean it is the useful
    # answer; overwriting in silence is not.
    RESERVED_HEADERS = {
      'authorization' => 'authentication is configured on the client: pass http_token:, oauth2_token:, or user: and password:, or build a second client with Client#with',
      'from'          => 'the From header is what on_behalf_of sets: use client.on_behalf_of(...) to perform requests for another user'
    }.freeze

    # The headers a request carries beyond the ones this class sets.
    #
    # Names are downcased, which is what makes two spellings of one header
    # comparable at all: HTTP treats them as the same header, so
    # +{'Accept' => 'a', 'accept' => 'b'}+ would otherwise send whichever Hash
    # order put last and drop the other without a word - the silent drop
    # {DuplicateKeys} exists to refuse.
    #
    # Values are stringified for the reason {#with_on_behalf_of} stringifies
    # the +From+ scope: a header is text on the wire, and a value of another
    # type reaches Net::HTTP intact and dies there with
    # `undefined method 'strip' for an instance of Integer`.
    #
    # Public for the same reason as {.stringify_query}: {Test} records what a
    # request would have carried, and a stand-in whose recorded values
    # disagree with the wire makes green tests mean less than they appear to.
    #
    # @api private
    # @param headers [Hash]
    # @return [Hash{String => String}]
    # @raise [ArgumentError] for a nil value, a value that is not text, two
    #   spellings of one header, or a header this class sets itself
    def self.stringify_headers(headers)
      DuplicateKeys
        .normalize(headers, noun: 'header') { it.to_s.downcase }
        .to_h { |name, value| [name, stringify_header_value(name, value)] }
    end

    # @api private
    # @return [String]
    def self.stringify_header_value(name, value)
      reserved = RESERVED_HEADERS[name]
      raise ArgumentError, "header #{name} is set by this client, not by a request: #{reserved}" if reserved
      raise ArgumentError, "header #{name} is nil, and a header is always text: pass a value, or leave the header out" if value.nil?
      raise ArgumentError, "header #{name} was given as #{value.inspect}, and a header is always text: pass a String" if !value.is_a?(String) && !value.is_a?(Symbol) && !value.is_a?(Numeric)

      value.to_s
    end

    # Percent-encodes one segment of a request path.
    #
    # Record ids are pasted into the path, and an id taken straight from a
    # request parameter used to be pasted in whole: `find("1/../../api/v1/
    # users/1")` resolved to the users endpoint, so the parameter, not the
    # call, chose which records the verb applied to. Encoding everything
    # outside the unreserved set keeps a separator inside the segment it was
    # written in, and a caller that really means a sub-path can spell it out
    # with the raw request methods.
    #
    # A dot segment is refused rather than encoded. `.` and `..` are unreserved
    # all the way through, so the encoding below returns them exactly as they
    # arrived and `find('..')` still resolved one path level up - onto the
    # index endpoint, and through a has_many path onto every article on the
    # instance offered as one ticket's. Percent-encoding the dots would hold
    # them inside the segment here, but a proxy that normalises a path before
    # routing it would undo that, and no Zammad record is named for one.
    #
    # Public for the same reason as {.stringify_query}: {Test} builds the
    # paths it records with it.
    #
    # @api private
    # @param value [Object]
    # @return [String]
    # @raise [ArgumentError] when there is nothing to send, or when the id
    #   navigates instead of naming a record
    def self.escape_path_segment(value)
      segment = value.to_s
      raise ArgumentError, 'a record id is required, and this one is empty' if segment.empty?
      raise ArgumentError, "#{segment.inspect} points at another endpoint rather than naming a record" if DOT_SEGMENTS.include?(segment)

      segment.gsub(UNRESERVED_IN_PATH) { |character| character.bytes.map { format('%%%02X', it) }.join }
    end

    # Strips the leading slashes from a path so that it resolves against the
    # instance URL rather than against the host.
    #
    # {Config#url} always ends in a slash and every request path is appended
    # relative to it, so a leading slash would drop the sub-path of a Zammad
    # served from one - `https://host/zammad/` + `/api/v1/tickets` resolves to
    # `https://host/api/v1/tickets`.
    #
    # Public for the same reason as {.stringify_query} and
    # {.escape_path_segment}: {Client} and {Test} both apply this rule, the
    # latter to decide which stub a request matches, and a path rule kept in
    # three places is one that gets changed in one of them - at which point
    # the stand-in quietly stops matching what the client sends.
    #
    # @api private
    # @param path [Object]
    # @return [String]
    def self.relative_path(path) = path.to_s.sub(%r{\A/+}, '')

    # @param config [Config]
    def initialize(config)
      @config       = config
      @on_behalf_of = nil
      @connection   = build_connection
    end

    # Returns a copy of this transport that sends the +From+ header.
    #
    # A user id is a documented way to name the user, and arrives here as an
    # Integer. Header values are stringified here rather than at the point the
    # header is set, so that {Test} records the value the wire would carry -
    # an Integer used to reach Net::HTTP intact and die there with
    # `undefined method 'strip' for an instance of Integer`, while the test
    # kit accepted it happily.
    #
    # @param identifier [String, Integer, nil] login, email or user id
    # @return [Transport]
    def with_on_behalf_of(identifier)
      copy = dup
      copy.instance_variable_set(:@on_behalf_of, identifier&.to_s)
      copy
    end

    # Returns a transport of this kind configured with +config+, keeping any
    # {#with_on_behalf_of} scope.
    #
    # {Client#with} goes through here rather than building a Transport itself,
    # so that a client whose transport was replaced - the test kit's stand-in,
    # say - derives another of the same kind instead of silently reverting to
    # a real HTTP one.
    #
    # @param config [Config]
    # @return [Transport]
    def with_config(config) = self.class.new(config).with_on_behalf_of(on_behalf_of)

    # Performs a request and raises on anything but a 2xx response.
    #
    # @param method [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @param path [String] path relative to {Config#url}
    # @param operation [String] description used in error messages
    # @param query [Hash, nil] query string parameters
    # @param body [Hash, nil] request payload, encoded as JSON
    # @param headers [Hash, nil] request headers, beyond the ones this class
    #   sets from the configuration
    # @param resource_class [Class, nil] used in error messages
    # @return [Response]
    # @raise [ResponseError] for non-2xx responses
    # @raise [TimeoutError] when the request timed out
    # @raise [ConnectionError] when the instance was unreachable
    #
    # Every failure leaves here as a {ZammadAPI::Error}. The bare socket
    # errors are caught alongside the Faraday ones because they are already
    # in {RETRIABLE_EXCEPTIONS}, which is this class saying it expects to see
    # them: an adapter that does not wrap them used to let them out raw once
    # the retries were spent, past every rescue a caller had written.
    def request(method, path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = decode(perform(method, path, query, body, headers))
      log_response(method, path, response, started)

      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    rescue Faraday::TimeoutError, *TIMEOUT_ERRORS => e
      raise TimeoutError, "Can't #{operation}: request to #{path} timed out (#{e.message})"
    rescue Faraday::SSLError, *SSL_ERRORS => e
      raise ConnectionError, "Can't #{operation}: TLS handshake with #{config.redacted_url} failed (#{e.message})"
    rescue Faraday::ConnectionFailed, *CONNECTION_ERRORS => e
      raise ConnectionError, "Can't #{operation}: #{config.redacted_url} is unreachable (#{e.message})"
    end

    private

    def perform(method, path, query, body, headers)
      # Built before the request is logged, so a rejected query or header does
      # not leave a line claiming a request that was never made.
      params = query && Transport.stringify_query(query)
      fields = headers && Transport.stringify_headers(headers)
      log_request(method, path, query, body, fields)

      @connection.public_send(method, path) do |request|
        request.params.update(params) if params
        # One at a time rather than in bulk, so that every name goes through
        # Faraday's own case-insensitive writer and replaces the header it
        # names rather than sitting beside it under another spelling.
        fields&.each { |name, value| request.headers[name] = value }
        request.body = body if body
        request.headers['From'] = on_behalf_of if on_behalf_of
      end
    end

    def build_connection
      connection = Faraday.new(
        url:     config.url,
        proxy:   config.proxy,
        ssl:     { verify: config.ssl_verify },
        request: { timeout: config.timeout, open_timeout: config.open_timeout },
        headers: { 'User-Agent' => config.user_agent, 'Accept' => 'application/json' }
      ) do |faraday|
        apply_authentication(faraday)
        faraday.request :json
        faraday.request :retry, retry_options
        # Last in the stack, so a caller's middleware sees the request as this
        # gem finished building it and the response before anything else does.
        config.middleware&.call(faraday)
        faraday.adapter(config.adapter || Faraday.default_adapter)
      end

      refuse_decoding_middleware!(connection)
      connection
    rescue ZammadAPI::Error
      raise
    rescue => e
      # An unregistered adapter, a proxy that is not a URL, or a middleware
      # that rejects its options is a configuration mistake, and neither
      # Faraday nor URI is part of this gem's surface.
      #
      # Caught as StandardError rather than as Faraday::Error, because the
      # failures that do not come from Faraday are the ones a caller is least
      # equipped to place: `proxy: 'http://user:pa ss@host'` escaped as
      # URI::InvalidURIError and a `middleware` callable that raises escaped
      # as whatever it raised, both straight past the
      # `rescue ZammadAPI::ConfigurationError` that building a client is
      # documented to need. The class is named in the message because
      # "bad URI (is not URI?)" on its own says nothing about where to look.
      raise ConfigurationError, "config could not be used to build a connection: #{e.class}: #{redact_config_values(e.message)}"
    end

    # The underlying error quotes the value it rejected, and for a proxy that
    # value carries its credentials: `proxy: 'http://user:pa ss@host:3128'`
    # came back as URI::InvalidURIError with the whole URL, password included,
    # in its message - and that message goes into the ConfigurationError
    # above, which lands in every log and exception report. The one case
    # {Config#inspect} and USERINFO_PATTERN exist to prevent, reached by
    # another route.
    #
    # The configured values are swapped for their redacted forms rather than
    # the message being dropped, because "bad URI (is not URI?)" without the
    # URI says nothing about where to look. Substring replacement, because
    # the message embeds the value verbatim, and the url as well as the proxy
    # because 1.x callers still put credentials in the instance URL.
    def redact_config_values(message)
      [config.proxy, config.url].compact.inject(message.to_s) do |text, value|
        redacted = config.redacted(value)

        # The block form. A String replacement expands the backslash
        # sequences it contains, and the replacement here is the configured
        # value with its userinfo blanked - so a value carrying `\0` or `\&`
        # put the whole matched text back, credentials included, into the
        # message it had just been taken out of, and one carrying `\1` cut
        # the replacement short instead.
        #
        # Both spellings of the value, because the error being quoted may
        # have inspected it rather than interpolated it: URI::InvalidURIError
        # does, and inspect escapes exactly the backslashes, quotes and
        # control characters that make a URL invalid in the first place. The
        # escaped text no longer equals the value as configured, so the swap
        # matched nothing and left the password standing in full - the case
        # this method exists for, reached through the quoting rather than
        # the value.
        inspected = value.inspect
        quoted    = inspected[1...-1] || inspected

        text.gsub(value) { redacted }.gsub(quoted) { redacted }
      end
    end

    def apply_authentication(faraday)
      case config.authentication_scheme
      when :http_token   then faraday.request :authorization, 'Token', config.http_token
      when :oauth2_token then faraday.request :authorization, 'Bearer', config.oauth2_token
      else                    faraday.request :authorization, :basic, config.user, config.password
      end
    end

    def retry_options
      {
        max:                 config.retries,
        interval:            config.retry_interval,
        interval_randomness: 0.5,
        backoff_factor:      2,
        retry_statuses:      RETRIABLE_STATUSES,
        methods:             RETRIABLE_METHODS,
        exceptions:          RETRIABLE_EXCEPTIONS
      }
    end

    def decode(faraday_response)
      headers    = faraday_response.headers.to_h.transform_keys { it.to_s.downcase }.freeze
      raw_body   = raw_body!(faraday_response.body)
      body, json = Response.decode_body(headers['content-type'], raw_body)

      Response.new(
        status:   faraday_response.status,
        headers:  headers,
        body:     body,
        raw_body: raw_body,
        json:     json
      )
    end

    # Middleware that reads the body before this gem can. Matched by name so
    # that naming one does not require it to be loaded.
    DECODING_MIDDLEWARE = %w[Faraday::Response::Json].freeze
    private_constant :DECODING_MIDDLEWARE

    # Refuses a stack that would decode the response body, while the stack is
    # still the only thing that has happened.
    #
    # `raw_body!` below catches the same mistake, but only once a response is
    # in hand - which is one request too late: `client.group.create(...)` sent
    # the POST, Zammad created the group, and only then did a
    # ConfigurationError come back, so a caller retrying what looked like a
    # configuration failure created a second one. The middleware is fully
    # visible here, where the unregistered adapter and the unusable proxy are
    # already refused before anything is sent.
    def refuse_decoding_middleware!(connection)
      offender = connection.builder.handlers.find { DECODING_MIDDLEWARE.include?(it.klass.name) }
      return if offender.nil?

      raise ConfigurationError,
            "the configured middleware includes #{offender.klass.name}, which decodes the response body before " \
            'this gem can. This gem parses JSON itself, and hands the undecoded bytes to attachment downloads, ' \
            'so it needs the body as it arrives: drop `c.response :json` from the `middleware:` callable.'
    end

    # The body as it came off the wire.
    #
    # `middleware:` is a documented seam and `c.response :json` is a
    # reasonable thing to put through it, at which point Faraday hands over a
    # Hash rather than the bytes. `to_s` turned that into a Ruby inspect
    # string, which JSON.parse then refused, so every record built from the
    # response died in {Response#decoded} with a ParseError naming Zammad for
    # what the caller's own stack had done.
    #
    # A backstop rather than the first line of defence: the stack is checked
    # when it is built, which catches `c.response :json` before a request goes
    # out. This is what is left for a middleware that decodes without being one
    # of the names that check knows.
    #
    # Said plainly instead. Re-encoding the parsed structure was the other
    # way out, and it is worse than it looks: {Response#raw_body} is
    # documented as the undecoded body and
    # {Resources::TicketArticleAttachment#download} hands exactly those bytes
    # back as the file, so a re-encoding silently returns something that is
    # not what Zammad stored - and JSON.generate has its own failures, which
    # would escape from here past the `rescue ZammadAPI::Error` every caller
    # is told to write. Once the bytes are gone they cannot be recovered, so
    # the honest answer is to name the cause while it is still visible.
    def raw_body!(body)
      return body.to_s if body.nil? || body.is_a?(String)

      raise ConfigurationError,
            'the configured middleware decoded the response body before this gem could ' \
            "(Faraday handed over #{body.class} rather than the raw body). This gem parses JSON itself, " \
            'and hands the undecoded bytes to attachment downloads, so it needs the body as it arrived: ' \
            'drop the parsing middleware - `c.response :json` is the usual one - from the `middleware:` callable.'
    end

    def log_request(method, path, query, body, headers)
      logger.debug { "Zammad API request: #{method.to_s.upcase} #{path}#{" query=#{redact(query).inspect}" if query}#{" headers=#{redact(headers).inspect}" if headers}" }
      logger.debug { "Zammad API payload: #{redact(body).inspect}" } if body
    end

    def log_response(method, path, response, started)
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      logger.debug { "Zammad API response: #{method.to_s.upcase} #{path} -> #{response.status} in #{duration}ms" }
    end

    def redact(value)
      case value
      when Hash  then value.to_h { |key, nested| [key, SENSITIVE_KEY_PATTERN.match?(key.to_s) ? REDACTED : redact(nested)] }
      when Array then value.map { redact(it) }
      else value
      end
    end

    def logger = config.logger
  end
end
