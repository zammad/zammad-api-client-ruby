# frozen_string_literal: true

require_relative 'errors'

module ZammadAPI
  # A decoded HTTP response.
  #
  # This deliberately does not expose Faraday objects, so that the HTTP client
  # stays an implementation detail of {Transport}.
  #
  # @!attribute [r] status
  #   @return [Integer] HTTP status code
  # @!attribute [r] headers
  #   @return [Hash{String => String}] response headers, keys downcased
  # @!attribute [r] body
  #   @return [Hash, Array, String] JSON responses are decoded with symbol
  #     keys; every other content type is left as the raw body
  # @!attribute [r] raw_body
  #   @return [String] the undecoded response body
  Response = Data.define(:status, :headers, :body, :raw_body)

  class Response
    SUCCESS_STATUSES = (200..299)

    # @return [Boolean] whether the status code is in the 2xx range
    def success? = SUCCESS_STATUSES.cover?(status)

    # @return [Boolean] whether {#body} was decoded from JSON
    def json? = !body.equal?(raw_body)

    # Returns the decoded body once it matches the expected shape.
    #
    # Zammad answers with an object for a single record and an array for a
    # list; anything else (a proxy error page, an unexpanded search result)
    # is a {ParseError} rather than a confusing failure further downstream.
    #
    # @param shape [Symbol] +:object+ or +:array+
    # @param operation [String] description used in the error message
    # @param resource_class [Class, nil] used in the error message
    # @return [Hash, Array]
    # @raise [ParseError] when the body has a different shape
    def decoded(shape, operation:, resource_class: nil)
      case [shape, body]
      in [:object, Hash => object] then object
      in [:array, Array => array] then array
      else
        raise ParseError.build(
          operation:      operation,
          expected:       shape,
          actual:         body.class,
          resource_class: resource_class
        )
      end
    end
  end
end
