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

    # There is no reader here for the size of the whole result, and the
    # absence is deliberate. This class carried a `reported_total` that read
    # an `x-total-count` response header, and two stop conditions were built
    # on it: {Collection#each} ended a walk one request early on it, and a
    # has_many reader refused a list it judged truncated by it.
    #
    # Zammad has never sent that header, from any endpoint. Its only custom
    # response header is `X-Failure`, and the totals it does report are
    # fields in a JSON body: `only_total_count` and `with_total_count` on a
    # search, `full` on the endpoints that render through
    # model_index_render. So the reader answered nil every time, both guards
    # were dead, and the one of them that could have acted - ending a walk on
    # a figure the records did not corroborate - was the one that could have
    # been wrong. {Collection#total_count} asks a search endpoint for its
    # figure the way Zammad actually offers it, and {#decoded_list} reads
    # the one a search reports beside a page.

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

    # Whether the response says that its body is JSON, which is not whether
    # the body then decoded as that: an empty one and one that does not parse
    # are left as they arrived, and {#json?} is false for both.
    #
    # What an answer says it is tells whose it is. Zammad answers a request
    # to its API with JSON, so a 2xx of another type - a login page, the
    # default page of a load balancer - is the answer of something in front
    # of it: see {Resources::Base#save!}.
    #
    # @return [Boolean]
    def json_content_type? = Response.json_type?(headers['content-type'])

    # The one reading of a content-type, for {.decode_body} and
    # {#json_content_type?} alike.
    #
    # @api private
    # @param content_type [String, nil]
    # @return [Boolean]
    def self.json_type?(content_type) = content_type.to_s.include?('json')

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
      return [raw_body, false] if !json_type?(content_type)
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

    # Returns the records of a list, and the size of the whole result where
    # the endpoint reports it beside them.
    #
    # A list is an array. A search asked for +with_total_count+ answers with
    # an object instead, +{records: [...], total_count: n}+, where its Zammad
    # reads that parameter under +expand+ - 6.5.1 and later - and with the
    # array it always did where it does not. Both are a list, and
    # {Collection} reads either.
    #
    # A total that cannot be one - a negative figure, a string - is reported
    # as none rather than refused. The records beside it are still the page,
    # and a walk without a total is a walk as it was before there was one.
    #
    # @param operation [String] description used in the error message
    # @param resource_class [Class, nil] used in the error message
    # @return [Array(Array<Hash>, Integer)] the records and the total
    # @return [Array(Array<Hash>, nil)] where the endpoint reported no total
    # @raise [ParseError] when the body is neither shape
    def decoded_list(operation:, resource_class: nil)
      case body
      in { records: Array => records, total_count: total }
        [array_of_objects!(records, operation: operation, resource_class: resource_class), total.is_a?(Integer) && !total.negative? ? total : nil]
      else
        [decoded(:array, operation: operation, resource_class: resource_class), nil]
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
    #
    # Asked for by position, because the element itself cannot say whether
    # one was found. `find` answers nil for no offender and for an offender
    # that is nil, so a list holding a JSON null - `[null]`, or one null
    # among the records - passed as a list of objects, and the same failure
    # came back one type over: NoMethodError for `nil[:id]`, from the walk
    # that reads the ids of a page.
    def array_of_objects!(array, operation:, resource_class:)
      position = array.index { !it.is_a?(Hash) }
      return array if position.nil?

      raise ParseError.build(
        operation:      operation,
        expected:       'array of objects',
        actual:         "an array holding #{array.fetch(position).class}",
        resource_class: resource_class
      )
    end
  end
end
