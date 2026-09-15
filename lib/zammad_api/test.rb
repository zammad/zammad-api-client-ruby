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
    # @!attribute [r] on_behalf_of
    #   @return [String, nil] the +From+ scope in effect, stringified the way
    #     the +From+ header carries it
    Request = Data.define(:verb, :path, :query, :body, :on_behalf_of)

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
    # @param body [Hash, Array, String, nil] a Hash or Array is served as
    #   JSON, anything else as a raw body
    # @param headers [Hash] response headers
    # @param query [Hash, nil] only answer requests carrying these parameters
    # @return [self]
    def stub(method, path, status: 200, body: nil, headers: {}, query: nil)
      # Stringified here rather than on each request, so that a query the
      # transport would refuse - a nil value - is reported against the line
      # that wrote the stub instead of against whichever request reached it.
      scope = query && ::ZammadAPI::Transport.stringify_query(query)

      @monitor.synchronize do
        (@stubs[key(method, path)] ||= []) << {
          status:  status,
          body:    body,
          headers: headers.to_h { |name, value| [name.to_s.downcase, value] },
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
    def answer(method, path, operation:, query: nil, body: nil, resource_class: nil, on_behalf_of: nil)
      relative = path.to_s.sub(%r{\A/+}, '')
      # Through the real transport's own stringification, so that {Request#query}
      # holds what a request would have carried rather than the raw Ruby values.
      # A stand-in that records a different shape than the wire makes an
      # assertion pass here and fail in production, or the other way round.
      params   = ::ZammadAPI::Transport.stringify_query(query || {})

      stub = @monitor.synchronize do
        @requests << Request.new(verb: method, path: relative, query: params, body: snapshot(body), on_behalf_of: on_behalf_of)
        take(method, relative, params)
      end

      raise UnstubbedRequestError, unstubbed_message(method, relative) if stub.nil?

      response = response_for(stub)
      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    end

    private

    def key(method, path) = [method.to_sym, path.to_s.sub(%r{\A/+}, '')]

    # A copy of the payload, frozen, for the record of what was sent.
    #
    # The caller's Hash used to be recorded by reference, so a test that built
    # one payload, sent it, then changed it for a second call rewrote the
    # first recorded request and asserted against a body that never went
    # anywhere. `query` is already a fresh structure by the time it gets here,
    # because the transport's stringification builds one; `body` is handed
    # over untouched, and was the one shape left sharing state with the test.
    def snapshot(value)
      case value
      when Hash   then value.to_h { |key, nested| [key, snapshot(nested)] }.freeze
      when Array  then value.map { snapshot(it) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    # Picks the stub that answers this request, and keeps the last one of its
    # kind in place so that one stub can answer any number of requests while
    # two describe a sequence.
    #
    # Sequencing runs within a query scope, not across the endpoint. Keying it
    # on the last stub queued meant a query-scoped stub was consumed on its
    # first use as soon as any other stub for the same verb and path existed
    # behind it - the pair a `search(...).count` test needs - so the second
    # count silently fell through to the records stub and walked the pages.
    def take(method, path, params)
      queued = @stubs[key(method, path)]
      return nil if queued.nil?

      matching = queued.each_index.select { matches?(queued[it][:query], params) }
      return nil if matching.empty?

      # A stub naming query parameters was written for this request; an
      # unscoped one is a catch-all for the endpoint. The specific ones answer
      # first, and only fall back when none of them match.
      scoped = matching.select { queued[it][:query] }
      group  = scoped.empty? ? matching : scoped

      group.one? ? queued[group.first] : queued.delete_at(group.first)
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

    def response_for(stub)
      case stub[:body]
      in Hash | Array => structured
        raw = JSON.generate(structured)
        build_response(stub, JSON.parse(raw, symbolize_names: true), raw, json: true)
      in nil
        build_response(stub, '', '', json: false)
      in other
        raw = other.to_s
        build_response(stub, raw, raw, json: false)
      end
    end

    def build_response(stub, body, raw_body, json:)
      Response.new(status: stub[:status], headers: stub[:headers], body: body, raw_body: raw_body, json: json)
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

      %i[get post put delete].each do |verb|
        define_method(verb) do |path, **options|
          request(verb, path, **options) # steep:ignore NoMethod
        end
      end

      def request(method, path, operation:, query: nil, body: nil, resource_class: nil)
        test.answer(
          method,
          path,
          operation:      operation,
          query:          query,
          body:           body,
          resource_class: resource_class,
          on_behalf_of:   on_behalf_of
        )
      end
    end
  end
end
