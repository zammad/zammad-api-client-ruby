# frozen_string_literal: true

require 'faraday'
require 'faraday/retry'
require 'uri'

module ZammadAPI
  # Performs the HTTP requests against a Zammad instance.
  #
  # Instances are immutable once built: {#with_on_behalf_of} returns a copy
  # rather than mutating shared state, which makes a single transport safe to
  # use from several threads.
  #
  # @api private
  class Transport
    # The verb shorthands, shared with {Test::Transport} so that the two answer
    # the same calls.
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

    # Methods that are retried: the ones that only read. A write that timed
    # out may still have been applied, so it is not sent twice.
    RETRIABLE_METHODS = %i[get head options].freeze

    # Statuses a read is retried on.
    RETRIABLE_STATUSES = [429, 500, 502, 503, 504].freeze

    # Errors a read is retried on. The adapter wraps socket and TLS errors
    # into Faraday's own classes.
    RETRIABLE_EXCEPTIONS = [Faraday::RetriableResponse, Faraday::ConnectionFailed, Faraday::TimeoutError].freeze

    # Keys whose values are never written to the log. Matched anywhere in the
    # name, as Zammad's own log filter does, so +monkey_id+ is hidden too.
    SENSITIVE_KEY_PATTERN = /passw|pwd|bind_pw|passphrase|secret|token|credential|cookie|authorization|key|otp|salt/i

    # What the log shows in place of a sensitive value.
    REDACTED = '[REDACTED]'

    # A path that opens with a scheme, which Faraday would send to that host.
    ABSOLUTE_URL = /\A[a-z][a-z0-9+.-]*:/i
    private_constant :ABSOLUTE_URL

    # @return [Config]
    attr_reader :config

    # @return [String, nil] the user requests are performed for, sent as the
    #   +From+ header
    attr_reader :on_behalf_of

    # The value of a +From+ header for {Client#on_behalf_of}.
    #
    # A blank identifier is refused: Zammad reads an empty +From+ header as
    # none, so every request would quietly run as the authenticated account.
    #
    # @param identifier [String, Integer] login, email address or user id
    # @return [String] frozen
    # @raise [ArgumentError] for an identifier that is nil or blank
    def self.on_behalf_of_header(identifier)
      text = identifier.to_s.strip
      raise ArgumentError, "on_behalf_of needs the login, email address or id of a user, got #{identifier.inspect}" if text.empty?

      text.freeze
    end

    # A record id as a path segment, percent-encoded.
    #
    # @param value [Integer, String]
    # @return [String]
    # @raise [ArgumentError] for an id that is nil or empty
    def self.escape_path_segment(value)
      segment = value.to_s
      raise ArgumentError, 'a record id is required' if segment.empty?

      URI.encode_uri_component(segment)
    end

    # A request path relative to the instance URL. A leading slash is
    # dropped, so paths can be pasted from the Zammad documentation.
    #
    # @param path [String]
    # @return [String]
    # @raise [ArgumentError] for an absolute URL, which would carry this
    #   client's credentials to another host
    def self.relative_path(path)
      relative = path.to_s.sub(%r{\A/+}, '')
      if ABSOLUTE_URL.match?(relative)
        raise ArgumentError, "a request path is relative to the instance URL, and this one is an absolute URL: pass the path alone, such as 'api/v1/tickets'"
      end

      relative
    end

    # A path as it may be logged or named in an error: without a query string
    # or fragment, which may carry a token.
    #
    # @param path [String]
    # @return [String]
    def self.redact_path(path) = path.to_s.sub(/[?#].*/m, '')

    # Replaces the values of sensitive keys, at any depth, for the log.
    #
    # @param value [Object]
    # @return [Object]
    def self.redact(value)
      case value
      when Hash  then value.to_h { |key, nested| [key, SENSITIVE_KEY_PATTERN.match?(key.to_s) ? REDACTED : redact(nested)] }
      when Array then value.map { redact(it) }
      else value
      end
    end

    # @param config [Config]
    # @param on_behalf_of [String, nil] see {.on_behalf_of_header}
    # @raise [ConfigurationError] when the connection cannot be built
    def initialize(config, on_behalf_of: nil)
      @config       = config
      @on_behalf_of = on_behalf_of
      @connection   = build_connection
    end

    # @param identifier [String, nil] see {.on_behalf_of_header}
    # @return [Transport] a copy that performs requests for that user
    def with_on_behalf_of(identifier)
      copy = dup
      copy.instance_variable_set(:@on_behalf_of, identifier)
      copy
    end

    # @param config [Config]
    # @return [Transport] a new transport for +config+, for the same user
    def with_config(config) = self.class.new(config, on_behalf_of: on_behalf_of)

    def inspect
      "#<#{self.class.name} url=#{config.url.inspect} auth=#{config.authentication_scheme}#{" on_behalf_of=#{on_behalf_of.inspect}" if on_behalf_of}>"
    end

    # Performs a request and raises on anything but a 2xx response.
    #
    # @param method [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @param path [String] path relative to {Config#url}
    # @param operation [String] description used in error messages
    # @param query [Hash, nil] query string parameters
    # @param body [Hash, Array, String, nil] request payload; a Hash or Array
    #   is encoded as JSON, a String is sent as it is
    # @param headers [Hash, nil] request headers
    # @param resource_class [Class, nil] used in error messages
    # @return [Response]
    # @raise [ResponseError] for non-2xx responses
    # @raise [TimeoutError] when the response took longer than {Config#timeout}
    # @raise [ConnectionError] when the instance was unreachable, including
    #   a connection not opened within {Config#open_timeout}
    def request(method, path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
      path = Transport.relative_path(path)
      log_request(method, path, query, body, headers)

      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = decode(perform(method, path, query, body, headers))
      log_response(method, path, response, started)
      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    rescue Faraday::TimeoutError => e
      raise TimeoutError, "Can't #{operation}: request to #{Transport.redact_path(path)} timed out (#{e.message})"
    rescue Faraday::SSLError => e
      raise ConnectionError, "Can't #{operation}: TLS handshake with #{config.url} failed (#{e.message})"
    rescue Faraday::ConnectionFailed => e
      raise ConnectionError, "Can't #{operation}: #{config.url} is unreachable (#{e.message})"
    end

    private

    # The connection's :json middleware encodes a Hash or Array body.
    def perform(method, path, query, body, headers)
      @connection.public_send(method, path) do |request|
        request.params.update(query) if query
        headers&.each { |name, value| request.headers[name.to_s] = value.to_s }
        request.headers['From'] = on_behalf_of if on_behalf_of
        request.body = body if body
      end
    end

    def build_connection
      Faraday.new(
        url:     config.url,
        ssl:     { verify: config.ssl_verify },
        proxy:   config.proxy,
        request: { timeout: config.timeout, open_timeout: config.open_timeout },
        headers: { 'User-Agent' => config.user_agent, 'Accept' => 'application/json' }
      ) do |faraday|
        apply_authentication(faraday)
        faraday.request :json
        faraday.request :retry, retry_options
        faraday.adapter(config.adapter) if config.adapter
        config.middleware&.call(faraday)
      end
    rescue Faraday::Error => e
      raise ConfigurationError, "config could not be used to build a connection: #{e.message}"
    end

    def retry_options
      {
        max:                 config.retries,
        interval:            config.retry_interval,
        max_interval:        config.timeout,
        interval_randomness: 0.5,
        backoff_factor:      2,
        retry_statuses:      RETRIABLE_STATUSES,
        methods:             RETRIABLE_METHODS,
        exceptions:          RETRIABLE_EXCEPTIONS
      }
    end

    def apply_authentication(faraday)
      case config.authentication_scheme
      when :http_token   then faraday.request :authorization, 'Token', config.http_token
      when :oauth2_token then faraday.request :authorization, 'Bearer', config.oauth2_token
      else                    faraday.request :authorization, :basic, config.user, config.password
      end
    end

    def decode(faraday_response)
      headers  = faraday_response.headers.to_h.to_h { |name, value| [name.to_s.downcase, value.to_s] }.freeze
      raw_body = faraday_response.body.to_s

      Response.new(
        status:   faraday_response.status,
        headers:  headers,
        body:     Response.decode_body(headers['content-type'], raw_body),
        raw_body: raw_body
      )
    end

    def log_request(method, path, query, body, headers)
      logger.debug do
        "Zammad API request: #{method.to_s.upcase} #{Transport.redact_path(path)}#{" query=#{Transport.redact(query).inspect}" if query}#{" headers=#{Transport.redact(headers).inspect}" if headers}"
      end
      logger.debug { "Zammad API payload: #{loggable_body(body)}" } if body
    end

    def log_response(method, path, response, started)
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      logger.debug { "Zammad API response: #{method.to_s.upcase} #{Transport.redact_path(path)} -> #{response.status} in #{duration}ms" }
    end

    def loggable_body(body)
      return Transport.redact(body).inspect if body.is_a?(Hash) || body.is_a?(Array)

      "[#{body.to_s.bytesize} bytes, not logged]"
    end

    def logger = config.logger
  end
end
