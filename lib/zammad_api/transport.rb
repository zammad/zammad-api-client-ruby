# frozen_string_literal: true

require 'faraday'
require 'faraday/retry'
require 'json'

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
    # HTTP methods that Zammad handles idempotently and that are therefore
    # safe to retry. POST is excluded on purpose - retrying it could create
    # duplicate tickets or users.
    RETRIABLE_METHODS = %i[get put delete head options].freeze

    # Transient statuses worth retrying.
    RETRIABLE_STATUSES = [429, 500, 502, 503, 504].freeze

    # Socket failures that mean the request ran out of time. Most adapters
    # wrap these into a Faraday error, but not all do, and this gem lets a
    # caller choose the adapter.
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
    # @api private
    # @param query [Hash]
    # @return [Hash{String => String, Array<String>, Hash}]
    # @raise [ArgumentError] for a nil value, at any depth
    def self.stringify_query(query)
      query.each_with_object({}) do |(key, value), result|
        result[key.to_s] = stringify_query_value(key.to_s, value)
      end
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
      when Hash  then value.to_h { |nested, inner| [nested.to_s, stringify_query_value("#{key}[#{nested}]", inner)] }
      when Array then value.each_with_index.map { |inner, index| stringify_query_value("#{key}[#{index}]", inner) }
      else value.to_s
      end
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

    # @!method get(path, operation:, query: nil, resource_class: nil)
    # @!method post(path, operation:, query: nil, body: nil, resource_class: nil)
    # @!method put(path, operation:, query: nil, body: nil, resource_class: nil)
    # @!method delete(path, operation:, query: nil, resource_class: nil)
    # @return [Response]
    %i[get post put delete].each do |verb|
      define_method(verb) do |path, **options|
        request(verb, path, **options) # steep:ignore NoMethod
      end
    end

    # Performs a request and raises on anything but a 2xx response.
    #
    # @param method [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @param path [String] path relative to {Config#url}
    # @param operation [String] description used in error messages
    # @param query [Hash, nil] query string parameters
    # @param body [Hash, nil] request payload, encoded as JSON
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
    def request(method, path, operation:, query: nil, body: nil, resource_class: nil)
      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = decode(perform(method, path, query, body))
      log_response(method, path, response, started)

      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    rescue Faraday::TimeoutError, *TIMEOUT_ERRORS => e
      raise TimeoutError, "Can't #{operation}: request to #{path} timed out (#{e.message})"
    rescue Faraday::SSLError => e
      raise ConnectionError, "Can't #{operation}: TLS handshake with #{config.redacted_url} failed (#{e.message})"
    rescue Faraday::ConnectionFailed, *CONNECTION_ERRORS => e
      raise ConnectionError, "Can't #{operation}: #{config.redacted_url} is unreachable (#{e.message})"
    end

    private

    def perform(method, path, query, body)
      # Built before the request is logged, so a rejected query does not leave
      # a line claiming a request that was never made.
      params = query && Transport.stringify_query(query)
      log_request(method, path, query, body)

      @connection.public_send(method, path) do |request|
        request.params.update(params) if params
        request.body = body if body
        request.headers['From'] = on_behalf_of if on_behalf_of
      end
    end

    def build_connection
      Faraday.new(
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
      raise ConfigurationError, "config could not be used to build a connection: #{e.class}: #{e.message}"
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
      headers    = faraday_response.headers.to_h.transform_keys { it.to_s.downcase }
      raw_body   = faraday_response.body.to_s
      body, json = decode_body(headers['content-type'], raw_body)

      Response.new(
        status:   faraday_response.status,
        headers:  headers,
        body:     body,
        raw_body: raw_body,
        json:     json
      )
    end

    # Only JSON responses are decoded. Anything else - a proxy error page, a
    # file download - is handed back untouched so that callers and error
    # messages can still work with it.
    #
    # Returns whether it decoded alongside the body, because this is the only
    # place that knows.
    def decode_body(content_type, raw_body)
      return [raw_body, false] if !content_type.to_s.include?('json')
      return [raw_body, false] if raw_body.empty?

      [JSON.parse(raw_body, symbolize_names: true), true]
    rescue JSON::ParserError
      [raw_body, false]
    end

    def log_request(method, path, query, body)
      logger.debug { "Zammad API request: #{method.to_s.upcase} #{path}#{" query=#{redact(query).inspect}" if query}" }
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
