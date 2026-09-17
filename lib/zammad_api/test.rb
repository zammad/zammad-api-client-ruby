# frozen_string_literal: true

require 'json'

require_relative '../zammad_api'

module ZammadAPI
  # A stand-in Zammad, for testing code that calls this client.
  #
  # Stub the endpoints the code under test will reach, hand it {#client}, then
  # assert against {#requests}. No HTTP stack is involved, so nothing has to be
  # intercepted at the socket level and the responses come back through the
  # same decoding, error mapping and record building as real ones.
  #
  # @example
  #   require 'zammad_api/test'
  #
  #   zammad = ZammadAPI::Test.new
  #   zammad.stub(:get, 'api/v1/tickets/1', body: {id: 1, title: 'Help', state: 'open'})
  #   zammad.stub(:put, 'api/v1/tickets/1', body: {id: 1, state: 'closed'})
  #
  #   TicketCloser.new(zammad.client).close(1)
  #
  #   zammad.requests.last.verb # => :put
  #   zammad.requests.last.body # => {state: "closed"}
  #
  # @example An error path
  #   zammad.stub(:get, 'api/v1/tickets/9', status: 404, body: {error: 'not found'})
  #   # the code under test sees ZammadAPI::NotFoundError
  class Test
    # Raised when the code under test reaches an endpoint that was not stubbed.
    #
    # The message lists what is stubbed, because the usual cause is a path that
    # differs from the expected one.
    #
    # Deliberately outside {ZammadAPI::Error}: this says the test is wrong, not
    # that Zammad refused something, and code under test is written to handle
    # the latter. Inside the hierarchy, the `rescue ZammadAPI::Error` that this
    # gem's own examples recommend swallowed a forgotten stub and reported it
    # as an API failure - so a test asserting the error path passed green over
    # a request it had never declared.
    class UnstubbedRequestError < StandardError; end

    # Raised when two stubs describe one request equally well.
    #
    # Two stubs that name different query parameters can both match a request
    # carrying all of them, and there is no honest way to rank them: a search
    # stubbed once for its records and once for its count is matched by both
    # when `count` sends the search term and +only_total_count+ together. The
    # stand-in used to pick one, hand back the wrong body, consume the stub on
    # the way past, and then report the endpoint as unstubbed - three
    # confusing symptoms for one fixable declaration.
    #
    # Outside {ZammadAPI::Error} for the same reason as
    # {UnstubbedRequestError}: it says the test is wrong, not that Zammad
    # refused anything.
    class AmbiguousStubError < StandardError; end

    # One request the code under test made.
    #
    # The verb is +verb+ rather than +method+, because a member named +method+
    # would shadow +Object#method+ on every recorded request.
    #
    # @!attribute [r] verb
    #   @return [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @!attribute [r] path
    #   @return [String] path relative to the instance URL
    # @!attribute [r] query
    #   @return [Hash{String => String, Array<String>}] query parameters as the
    #     client sent them, stringified the way the real transport sends them
    # @!attribute [r] body
    #   @return [Hash, nil] the request payload
    # @!attribute [r] headers
    #   @return [Hash{String => String}] the headers the call asked for,
    #     downcased and stringified the way the real transport sends them.
    #     Empty for a request that named none; the headers the client sets
    #     from its own configuration are not in here, and the +From+ scope has
    #     a member of its own below.
    # @!attribute [r] on_behalf_of
    #   @return [String, nil] the +From+ scope in effect, stringified the way
    #     the +From+ header carries it
    Request = Data.define(:verb, :path, :query, :body, :headers, :on_behalf_of)

    # @return [Config] the configuration the stand-in client reports
    attr_reader :config

    # @param options [Hash] any option accepted by {Config}; the defaults are
    #   enough for a client that never opens a connection
    def initialize(**options)
      @config    = Config.new(url: 'https://zammad.test/', http_token: 'test-token', **options)
      @stubs     = {}
      @requests  = []
      @monitor   = Mutex.new
      @transport = Transport.new(self)
      # Built once, and built straight onto the stand-in. Going through
      # `Client.new` re-validated the config assembled one line above and then
      # assembled a whole Faraday stack - auth, JSON, retries, adapter - only
      # to swap it straight back out, which is the cost the comment here used
      # to claim it was avoiding. A suite writing
      # `let(:zammad) { ZammadAPI::Test.new }` paid it once per example.
      @client    = Client.build(@config, @transport)
    end

    # A client that talks to this stand-in instead of to a Zammad.
    #
    # The same client every time; it holds no per-request state, and
    # {Client#on_behalf_of} and {Client#with} return copies of their own.
    #
    # @return [Client]
    attr_reader :client

    # Declares the response for one endpoint.
    #
    # Stubbing the same method and path again queues a second response: the
    # first request gets the first, and the last stub answers every request
    # after it. A +query+ matches when every parameter it names is present in
    # the request with that value, so a stub does not have to repeat the
    # +expand+, +page+ and +per_page+ parameters the client adds itself.
    #
    # A stub that names a +query+ is more specific than one that does not, and
    # answers ahead of it however they were declared. Queueing applies within
    # a scope: two stubs carrying the same +query+ describe a sequence, while
    # a scoped stub and a catch-all are two separate answers, each of which
    # keeps answering.
    #
    # @param method [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @param path [String] path relative to the instance URL, leading slash
    #   optional
    # @param status [Integer] HTTP status to answer with
    # @param body [Hash, Array, String, nil] a Hash or Array is serialized to
    #   JSON bytes, anything else is served as it is. Whether those bytes are
    #   then decoded is decided by the content-type, the way a real response
    #   decides it - so a Hash served as +text/html+ comes back undecoded, and
    #   a JSON String served as +application/json+ comes back decoded.
    # @param headers [Hash] response headers. Names and values are stringified
    #   and names downcased, the way a {Response} carries them. A Hash or Array
    #   body is given +content-type: application/json+ unless this says
    #   otherwise.
    # @param query [Hash, nil] only answer requests carrying these parameters
    # @return [self]
    def stub(method, path, status: 200, body: nil, headers: {}, query: nil)
      # Stringified here rather than on each request, so that a query the
      # transport would refuse - a nil value - is reported against the line
      # that wrote the stub instead of against whichever request reached it.
      scope = query && ::ZammadAPI::Transport.stringify_query(query)
      # A scope that names nothing matches every request, which is what a stub
      # with no query at all is. Kept apart, the two were equally specific and
      # `query: {}` collided with a catch-all as an ambiguous pair rather than
      # joining it.
      scope = nil if scope.nil? || scope.empty?

      # Refused here rather than stringified into something the wire could not
      # carry, and for the same reason the query above is: the error names the
      # line that wrote the stub. A nil `Content-Type` became `''`, which then
      # beat the JSON default this method supplies and served a Hash body
      # undecoded, so the test failed inside the code under test with nothing
      # to say the stub was at fault.
      headers.each do |name, value|
        next if value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric)

        raise ArgumentError, "header #{name} was stubbed as #{value.inspect}, and a response header is always text: pass a String"
      end

      @monitor.synchronize do
        (@stubs[key(method, path)] ||= []) << {
          status:  status,
          body:    body,
          headers: response_headers(headers, body),
          query:   scope
        }
      end
      self
    end

    # Every request the code under test made, oldest first.
    #
    # @return [Array<Request>]
    def requests = @monitor.synchronize { @requests.dup.freeze }

    # Forgets the stubs and the recorded requests.
    #
    # @return [self]
    def reset
      @monitor.synchronize do
        @stubs.clear
        @requests.clear
      end
      self
    end

    # @return [Array<String>] one +"GET api/v1/groups"+ per stubbed endpoint
    def stubbed = @monitor.synchronize { @stubs.keys.map { |method, path| "#{method.to_s.upcase} #{path}" } }

    # Reads both collections under the monitor, and reaches for @stubs rather
    # than {#stubbed} because the monitor is a plain Mutex and would deadlock
    # on the way back in. The counts used to be read outside it, so printing a
    # stand-in from a failure message or a debugger raced the thread under
    # test appending to @requests - which is the one thing the monitor is here
    # to prevent.
    def inspect = @monitor.synchronize { "#<#{self.class.name} stubbed=#{@stubs.size} requests=#{@requests.size}>" }

    # Answers a request from the stubs, recording it first.
    #
    # This is the {Transport} interface, called by the client rather than by a
    # test.
    #
    # @api private
    # @return [Response]
    # @raise [ResponseError] for a stubbed non-2xx status
    # @raise [UnstubbedRequestError] when no stub matches
    def answer(method, path, operation:, query: nil, body: nil, headers: nil, resource_class: nil, on_behalf_of: nil)
      relative = ::ZammadAPI::Transport.relative_path(path)
      # Through the real transport's own stringification, so that {Request#query}
      # and {Request#headers} hold what a request would have carried rather
      # than the raw Ruby values. A stand-in that records a different shape
      # than the wire makes an assertion pass here and fail in production, or
      # the other way round - and the header rules are where that matters
      # most, because a reserved name or a non-text value is refused on the
      # wire and would otherwise sail through here.
      params   = ::ZammadAPI::Transport.stringify_query(query || {})
      fields   = ::ZammadAPI::Transport.stringify_headers(headers || {})

      stub = @monitor.synchronize do
        @requests << Request.new(verb: method, path: relative, query: params, body: snapshot(body), headers: fields, on_behalf_of: on_behalf_of)
        take(method, relative, params)
      end

      raise UnstubbedRequestError, unstubbed_message(method, relative) if stub.nil?

      response = response_for(stub, params)
      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    end

    private

    def key(method, path) = [method.to_sym, ::ZammadAPI::Transport.relative_path(path)]

    # The headers a stub answers with, downcased the way a {Response} carries
    # them.
    #
    # A Hash or Array body is served as JSON, so it gets the content-type a
    # real one would. {Transport#decode} always hands over a response whose
    # headers name the type - it is what the decode branches on - while this
    # set `json: true` directly and left the headers as written, so every
    # stubbed response differed from the wire in a header a test can read.
    # Code that branches on `response.headers['content-type']` passed against
    # Zammad and failed against the stand-in, or the reverse, which is the
    # divergence this kit exists to keep out.
    #
    # A caller's own content-type wins, so a test can still say the endpoint
    # answered with something else.
    def response_headers(headers, body)
      # Values stringified as well as names. Only the name was normalised, so
      # `headers: { 'X-Total-Count' => 7 }` reached the code under test as an
      # Integer where the wire always carries "7": an assertion written the
      # natural way passed against Zammad and failed here, or the reverse, and
      # the one reader inside this gem had to tolerate both types to cope.
      # Downcasing is what creates the collision, so it is refused here rather
      # than merged: `{'Content-Type' => 'text/html', 'content-type' =>
      # 'application/json'}` kept whichever Hash order put last and dropped the
      # other without a word - the same silent drop DuplicateKeys refuses for a
      # query parameter, and here it decided whether the body was decoded.
      normalized = DuplicateKeys
        .normalize(headers, noun: 'header') { it.to_s.downcase }
        .transform_values(&:to_s)
      return normalized if !body.is_a?(Hash) && !body.is_a?(Array)

      { 'content-type' => 'application/json' }.merge(normalized)
    end

    # A copy of the payload, frozen, for the record of what was sent.
    #
    # The caller's Hash used to be recorded by reference, so a test that built
    # one payload, sent it, then changed it for a second call rewrote the
    # first recorded request and asserted against a body that never went
    # anywhere. `query` is already a fresh structure by the time it gets here,
    # because the transport's stringification builds one; `body` is handed
    # over untouched, and was the one shape left sharing state with the test.
    def snapshot(value) = DeepCopy.frozen_copy(value)

    # Picks the stub that answers this request, and keeps the last one of its
    # kind in place so that one stub can answer any number of requests while
    # two describe a sequence.
    #
    # Sequencing runs within a query scope, not across the endpoint. Keying it
    # on the last stub queued meant a query-scoped stub was consumed on its
    # first use as soon as any other stub for the same verb and path existed
    # behind it - the pair a `search(...).count` test needs - so the second
    # count silently fell through to the records stub and walked the pages.
    #
    # A scope here is the exact set of parameters a stub names, not merely the
    # fact that it names some. Grouped by whether a stub was scoped at all,
    # two stubs carrying *different* scopes were read as a sequence and the
    # first was consumed: stubbing a search once for its records and once for
    # its count made `count` eat the records stub, hand back an Array where a
    # count belonged, and then raise UnstubbedRequestError for a page that was
    # stubbed all along.
    #
    # The most specific scope answers, counting the parameters it pins, so a
    # stub written for one request still wins over a catch-all for the
    # endpoint however they were declared. Scopes that tie are genuinely
    # ambiguous and say so.
    def take(method, path, params)
      queued = @stubs[key(method, path)]
      return nil if queued.nil?

      matching = queued.each_index.select { matches?(queued[it][:query], params) }
      return nil if matching.empty?

      group = most_specific(queued, matching, method, path)

      group.one? ? queued[group.first] : queued.delete_at(group.first)
    end

    # The matching stubs that share the most specific scope, in the order they
    # were declared.
    #
    # @raise [AmbiguousStubError] when two scopes are equally specific
    def most_specific(queued, matching, method, path)
      scopes = matching.group_by { queued[it][:query] }
      depth  = scopes.keys.to_h { [it, it.nil? ? 0 : it.size] }
      best   = depth.values.max

      winners = scopes.select { |scope, _| depth[scope] == best }
      raise AmbiguousStubError, ambiguous_message(method, path, winners.keys) if winners.size > 1

      winners.values.first
    end

    def ambiguous_message(method, path, scopes)
      rendered = scopes.map { "query: #{it.inspect}" }.join(' and ')
      "#{method.to_s.upcase} #{path} is matched equally well by #{scopes.size} stubs (#{rendered}), " \
        'and this stand-in will not guess which one you meant. Name the parameters that tell the requests apart ' \
        '- a count stub that also carries the search term is more specific than one that does not - or leave the ' \
        'more general stub unscoped, which makes it a catch-all that answers only what the scoped ones do not.'
    end

    # Both sides have been through the transport's own stringification, the
    # stub's when it was declared. Comparing a raw value against a stringified
    # one worked for a scalar - `1.to_s` is `"1"` either way - and could never
    # match for an Array: `[1, 2].to_s` is `"[1, 2]"` while the recorded
    # `["1", "2"].to_s` is `"[\"1\", \"2\"]"`. `ids`, `role_ids`, `group_ids`
    # and `permissions` are all array-valued search parameters, so a stub
    # scoped to any of them silently never answered and the request came back
    # as unstubbed.
    def matches?(expected, params)
      return true if expected.nil?

      expected.all? { |name, value| params[name] == value }
    end

    # The records a stub holds are one page of them, not the answer to every
    # page.
    #
    # A collection walks until a page repeats, comes back short, or comes back
    # empty. A stub that keeps serving the same records to every page trips
    # the first of those, so the obvious way to stand in for a list endpoint -
    # one `stub(:get, 'api/v1/groups', body: [...])` - made every full read of
    # that collection raise PaginationError, and the only way to find that out
    # was to hit it. Against a real Zammad the same code works, because page 2
    # comes back empty; the stand-in is what differed.
    #
    # So a stub that does not name a page answers one, and a request for any
    # page after it gets an empty one. A stub that does name a page is left
    # exactly as written - that is how a test says what the second page holds.
    def paged_body(stub, params, body)
      return body if !body.is_a?(Array) || stub[:query]&.key?('page')
      return body if [nil, '1'].include?(params['page'])

      []
    end

    # Decoded by {Response.decode_body}, the rule {Transport#decode} reads, so
    # that a stub answers the way the wire does.
    #
    # `json:` used to be set from the Ruby type of the stub's body, which made
    # the content-type beside it decorative: a stub could say `text/html` and
    # still hand back a decoded Hash with `json?` true, where Zammad gives the
    # raw string and `decoded(:object)` raises ParseError. A test asserting
    # that path passed here and failed in production, which is the divergence
    # this kit exists to rule out.
    # Paged after decoding, not before. Paging read the stub's body as written,
    # which was the same thing only while a list could arrive as an Array - and
    # once the content-type decided decoding, a list stubbed as a JSON string
    # decoded to one and was never paged, so it answered every page with the
    # same records and every full read of that collection raised
    # PaginationError. Against Zammad the same code works, because page two
    # comes back empty.
    def response_for(stub, params)
      raw        = raw_body_for(stub[:body])
      body, json = Response.decode_body(stub[:headers]['content-type'], raw)
      paged      = paged_body(stub, params, body)
      # Re-serialized only where paging replaced the body, so `raw_body` stays
      # the bytes the stub was written with for every other response.
      return build_response(stub, body, raw, json: json) if paged.equal?(body)

      build_response(stub, paged, JSON.generate(paged), json: json)
    end

    # The bytes a stub's body would have arrived as. A Hash or Array is what a
    # test writes when it means JSON, so that is what it is serialized to;
    # anything else is already the body.
    def raw_body_for(body)
      case body
      when Hash, Array then JSON.generate(body)
      when nil         then ''
      else                  body.to_s
      end
    end

    # A copy, because the stub keeps serving after this response is built and
    # Response is a value. Handing out the stub's own Hash made every response
    # from one stub share it, so a test that wrote to `response.headers` -
    # editing a content-type to check a decode path, say - rewrote the
    # stand-in for every later request in the example. The real transport builds a fresh
    # hash per response, and this exists to behave like it.
    def build_response(stub, body, raw_body, json:)
      Response.new(status: stub[:status], headers: stub[:headers].dup.freeze, body: body, raw_body: raw_body, json: json)
    end

    def unstubbed_message(method, path)
      stubbed_endpoints = stubbed.empty? ? 'nothing is stubbed' : "stubbed: #{stubbed.join(', ')}"
      "#{method.to_s.upcase} #{path} was not stubbed on this #{self.class.name} (#{stubbed_endpoints})"
    end

    # Routes the client's requests to {Test#answer}, and carries the
    # +on_behalf_of+ scope the way the real transport does.
    #
    # @api private
    class Transport
      include ::ZammadAPI::Transport::Verbs

      attr_reader :test, :on_behalf_of

      def initialize(test, on_behalf_of: nil)
        @test         = test
        @on_behalf_of = on_behalf_of
      end

      def config = test.config

      # Stringified like the real transport's, so that a recorded scope is what
      # a request would have carried.
      def with_on_behalf_of(identifier) = self.class.new(test, on_behalf_of: identifier&.to_s)

      # {Client#with} re-validates the options and hands them here. There is
      # no connection to rebuild, and the derived client reports the derived
      # config itself, so the stand-in keeps answering.
      def with_config(_config) = self

      def request(method, path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
        test.answer(
          method,
          path,
          operation:      operation,
          query:          query,
          body:           body,
          headers:        headers,
          resource_class: resource_class,
          on_behalf_of:   on_behalf_of
        )
      end
    end
  end
end
