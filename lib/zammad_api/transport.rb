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

    # Failures worth retrying. Faraday::RetriableResponse is how the retry
    # middleware signals a retriable status internally and must stay in this
    # list, otherwise it escapes as an unhandled Faraday error.
    RETRIABLE_EXCEPTIONS = [
      Faraday::RetriableResponse,
      Faraday::ConnectionFailed,
      Faraday::TimeoutError,
      Errno::ETIMEDOUT,
      Timeout::Error
    ].freeze

    # Substrings that mark a request payload key as carrying a credential.
    # Matching on a substring rather than the whole key covers the variants
    # Zammad and OAuth actually send - password_confirm, access_token,
    # refresh_token, client_secret - which an exact-match list silently let
    # through to the log.
    SENSITIVE_KEY_PATTERN = /password|token|secret|private_key/i

    REDACTED = '[REDACTED]'

    # @return [Config]
    attr_reader :config

    # @return [String, nil] login of the user requests are performed for
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
    # @return [Hash{String => String, Array<String>}]
    # @raise [ArgumentError] for a nil value
    def self.stringify_query(query)
      query.each_with_object({}) do |(key, value), result|
        raise ArgumentError, "query parameter #{key} is nil, and Zammad has no way to read that: pass a value, or leave the parameter out" if value.nil?

        result[key.to_s] = value.is_a?(Array) ? value.map(&:to_s) : value.to_s
      end
    end

    # @param config [Config]
    def initialize(config)
      @config       = config
      @on_behalf_of = nil
      @connection   = build_connection
    end

    # Returns a copy of this transport that sends the +From+ header.
    #
    # @param identifier [String, nil] login, email or user id
    # @return [Transport]
    def with_on_behalf_of(identifier)
      copy = dup
      copy.instance_variable_set(:@on_behalf_of, identifier)
      copy
    end

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
    def request(method, path, operation:, query: nil, body: nil, resource_class: nil)
      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = decode(perform(method, path, query, body))
      log_response(method, path, response, started)

      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    rescue Faraday::TimeoutError => e
      raise TimeoutError, "Can't #{operation}: request to #{path} timed out (#{e.message})"
    rescue Faraday::SSLError => e
      raise ConnectionError, "Can't #{operation}: TLS handshake with #{config.url} failed (#{e.message})"
    rescue Faraday::ConnectionFailed => e
      raise ConnectionError, "Can't #{operation}: #{config.url} is unreachable (#{e.message})"
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
    rescue Faraday::Error => e
      # An unregistered adapter or a middleware that rejects its options is a
      # configuration mistake, and Faraday is not part of this gem's surface.
      raise ConfigurationError, "config could not be used to build a connection: #{e.message}"
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
