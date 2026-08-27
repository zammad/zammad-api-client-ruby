# frozen_string_literal: true

module ZammadAPI
  # Base class for every error raised by this gem.
  #
  # Rescuing +ZammadAPI::Error+ catches all of them.
  class Error < StandardError
    # Formats the "<operation> (<ResourceClass>)" fragment shared by error
    # messages, so every error reads the same way.
    #
    # @api private
    # @param operation [String]
    # @param resource_class [Class, nil]
    # @return [String]
    def self.subject_for(operation, resource_class)
      resource_class ? "#{operation} (#{resource_class.name})" : operation
    end
  end

  # Raised when {Config} cannot be built from the supplied options.
  class ConfigurationError < Error; end

  # Raised when a resource name is requested that this client does not know
  # about, e.g. +client.unicorn+.
  class UnknownResourceError < Error; end

  # Base class for failures that prevented a request from completing.
  class TransportError < Error; end

  # Raised when the connection to the Zammad instance could not be
  # established (DNS, refused connection, TLS failure, ...).
  class ConnectionError < TransportError; end

  # Raised when a request exceeded {Config#open_timeout} or {Config#timeout}.
  class TimeoutError < TransportError; end

  # Raised when a response did not have the shape the caller expected.
  class ParseError < Error
    # @param operation [String]
    # @param expected [Symbol] +:object+ or +:array+
    # @param actual [Class] the class that was decoded instead
    # @param resource_class [Class, nil]
    # @return [ParseError]
    def self.build(operation:, expected:, actual:, resource_class: nil)
      new("Can't #{subject_for(operation, resource_class)}: expected a JSON #{expected}, got #{actual}")
    end
  end

  # Base class for errors carrying an HTTP response.
  #
  # Use {.build} rather than +new+ to get the most specific subclass for a
  # given status code.
  class ResponseError < Error
    # @return [Faraday::Response, nil]
    attr_reader :response

    # @return [String] human readable description of what was attempted
    attr_reader :operation

    # @return [Class, nil] the resource class involved, when applicable
    attr_reader :resource_class

    # Returns the most specific error class for +response+ and instantiates it.
    #
    # @param response [Faraday::Response, nil]
    # @param operation [String]
    # @param resource_class [Class, nil]
    # @return [ResponseError]
    def self.build(response, operation:, resource_class: nil)
      error_class_for(response).new(
        response:       response,
        operation:      operation,
        resource_class: resource_class
      )
    end

    # @api private
    def self.error_class_for(response)
      return self if response.nil?

      STATUS_ERRORS.fetch(response.status) do
        response.status >= 500 ? ServerError : ClientError
      end
    end
    private_class_method :error_class_for

    def initialize(operation:, response: nil, resource_class: nil)
      @operation      = operation
      @response       = response
      @resource_class = resource_class
      super(build_message)
    end

    # @return [Integer, nil] HTTP status code
    def status
      response&.status
    end

    # @return [Hash, String, nil] parsed JSON body, or the raw body for
    #   non-JSON responses
    def body
      response&.body
    end

    # @return [Hash] response headers, empty when there is no response
    def headers
      response&.headers || {}
    end

    # @return [String, nil] the error message reported by Zammad, if any
    def server_message
      return nil if !body.is_a?(Hash)

      value = body[:error_human] || body[:error] || body['error_human'] || body['error']
      value.to_s.empty? ? nil : value.to_s
    end

    private

    def build_message
      "Can't #{Error.subject_for(operation, resource_class)}: #{detail}"
    end

    def detail
      server_message || (status ? "HTTP #{status}" : 'no response')
    end
  end

  # Any 4xx response that has no more specific subclass.
  class ClientError < ResponseError; end

  # Any 5xx response.
  class ServerError < ResponseError; end

  # 401 - credentials missing, wrong, or expired.
  class AuthenticationError < ClientError; end

  # 403 - authenticated, but not permitted to perform the operation.
  class AuthorizationError < ClientError; end

  # 404 - the requested record does not exist.
  class NotFoundError < ClientError; end

  # 422 - Zammad rejected the submitted attributes.
  class ValidationError < ClientError; end

  # 429 - too many requests.
  class RateLimitError < ClientError
    # @return [Integer, nil] value of the +Retry-After+ response header
    def retry_after
      value = headers['retry-after'] || headers['Retry-After']
      return nil if value.nil?

      Integer(value, exception: false)
    end
  end

  class ResponseError
    STATUS_ERRORS = {
      401 => AuthenticationError,
      403 => AuthorizationError,
      404 => NotFoundError,
      422 => ValidationError,
      429 => RateLimitError
    }.freeze
    private_constant :STATUS_ERRORS
  end
end
