# frozen_string_literal: true

require 'json'

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

    # Header Zammad's index endpoints report the size of the whole result in.
    # Keys are downcased by the time a Response carries them.
    #
    # Private, as it was on Collection before both readers of it came here:
    # {#reported_total} is the way to ask, and the signatures this gem
    # publishes are its API.
    TOTAL_COUNT_HEADER = 'x-total-count'
    private_constant :TOTAL_COUNT_HEADER

    # @return [Boolean] whether the status code is in the 2xx range
    def success? = SUCCESS_STATUSES.cover?(status)

    # How many records the endpoint says the whole query has.
    #
    # Here rather than on the two readers of it, because it is a fact about a
    # response and both of them had their own copy: {Collection} kept the
    # header name in a private constant and refused a negative count, while
    # {Associations::Proxy} hardcoded the string and accepted any Integer. A
    # rule kept in two places is one that gets changed in one of them.
    #
    # A negative count is refused rather than trusted: it cannot describe a
    # result, and both callers use this to decide whether they have seen every
    # record, where a nonsense figure is worse than none.
    #
    # Stringified before it is read. Every producer of a Response hands over
    # String header values - Faraday does, and {Test} normalises them - so this
    # is for a Response built by hand, where `Integer(5, 10, exception: false)`
    # is nil: a base cannot be given for a non-String and the exception is
    # swallowed, so a count would read as no count at all, which is the one
    # answer that turns the guard off silently.
    #
    # @return [Integer, nil] nil when the header was absent or not a count
    def reported_total
      reported = headers[TOTAL_COUNT_HEADER]
      return nil if reported.nil?

      total = Integer(reported.to_s, 10, exception: false)
      total if total&.>=(0)
    end

    # Recorded at decode time, where the answer is known, rather than derived
    # from `body` and `raw_body` being the same object. That identity held only
    # while every producer was careful to hand the same String to both, and any
    # edit that duped, re-encoded or normalised the raw body would have flipped
    # this to true with nothing asserting otherwise.
    #
    # @return [Boolean] whether {#body} was decoded from JSON
    def json? = json

    # Decodes a body the way this gem decodes every body, and says whether it
    # did.
    #
    # Only JSON responses are decoded. Anything else - a proxy error page, a
    # file download - is handed back untouched so that callers and error
    # messages can still work with it.
    #
    # Here rather than on {Transport}, because {Test} has to answer the same
    # way and was deciding from the Ruby type of the stub's body instead: a
    # stub could declare `content-type: text/html` and still hand back a
    # decoded Hash with `json?` true, where Zammad would have given the raw
    # string and a ParseError. A stand-in whose decoding disagrees with the
    # wire is the thing that kit exists to rule out.
    #
    # Public for that reason and no other, the way {Transport.stringify_query}
    # is: both transports call it from outside this class. It is not part of
    # what this gem promises a caller.
    #
    # @api private
    # @param content_type [String, nil]
    # @param raw_body [String]
    # @return [Array(Hash | Array | String, bool)] the body and whether it was
    #   decoded from JSON
    def self.decode_body(content_type, raw_body)
      return [raw_body, false] if !content_type.to_s.include?('json')
      return [raw_body, false] if raw_body.empty?

      [JSON.parse(raw_body, symbolize_names: true), true]
    rescue JSON::ParserError
      [raw_body, false]
    end

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
