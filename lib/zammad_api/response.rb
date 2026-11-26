# frozen_string_literal: true

require 'json'

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
    # @return [Boolean] whether the status code is in the 2xx range
    def success? = status.between?(200, 299)

    # Decodes a JSON body with symbol keys. Anything else - a proxy error page,
    # a file download, a body that does not parse - is handed back as it is.
    #
    # @api private
    # @param content_type [String, nil]
    # @param raw_body [String]
    # @return [Hash, Array, String]
    def self.decode_body(content_type, raw_body)
      return raw_body if !content_type.to_s.include?('json') || raw_body.empty?

      JSON.parse(raw_body, symbolize_names: true)
    rescue JSON::ParserError
      raw_body
    end

    # The body, checked to be the JSON object or array the caller expects.
    #
    # @param shape [:object, :array]
    # @param operation [String]
    # @param resource_class [Class, nil]
    # @return [Hash, Array]
    # @raise [ParseError] when the body has another shape
    def decoded(shape, operation:, resource_class: nil)
      return body if body.is_a?(shape == :object ? Hash : Array)

      raise ParseError.build(operation: operation, expected: shape, actual: body.class, resource_class: resource_class)
    end
  end
end
