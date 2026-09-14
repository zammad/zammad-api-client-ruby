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
  # @!attribute [r] json
  #   @return [Boolean] whether {#body} was decoded from JSON
  Response = Data.define(:status, :headers, :body, :raw_body, :json)

  class Response
    SUCCESS_STATUSES = (200..299)

    # @return [Boolean] whether the status code is in the 2xx range
    def success? = SUCCESS_STATUSES.cover?(status)

    # Recorded at decode time, where the answer is known, rather than derived
    # from `body` and `raw_body` being the same object. That identity held only
    # while every producer was careful to hand the same String to both, and any
    # edit that duped, re-encoded or normalised the raw body would have flipped
    # this to true with nothing asserting otherwise.
    #
    # @return [Boolean] whether {#body} was decoded from JSON
    def json? = json

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
      in [:array, Array => array] then array_of_objects!(array, operation: operation, resource_class: resource_class)
      else
        raise ParseError.build(
          operation:      operation,
          expected:       shape,
          actual:         body.class,
          resource_class: resource_class
        )
      end
    end

    private

    # Only the top-level shape used to be checked, which is not what the
    # promise above says. A search answering `[1, 2, 3]` - what an unexpanded
    # one looks like - passed as an array, and every element went to
    # `from_response`, which stored the Integer as a record's attributes. The
    # first `record.id` then died with `TypeError: no implicit conversion of
    # Symbol into Integer` from deep inside the gem: precisely the confusing
    # failure further downstream.
    def array_of_objects!(array, operation:, resource_class:)
      offender = array.find { !it.is_a?(Hash) }
      return array if offender.nil?

      raise ParseError.build(
        operation:      operation,
        expected:       'array of objects',
        actual:         "an array holding #{offender.class}",
        resource_class: resource_class
      )
    end
  end
end
