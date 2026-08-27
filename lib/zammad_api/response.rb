# frozen_string_literal: true

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
    def success?
      (200..299).cover?(status)
    end

    # @return [Boolean] whether {#body} was decoded from JSON
    def json?
      !body.equal?(raw_body)
    end
  end
end
