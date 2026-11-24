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
    # Deliberately outside {ZammadAPI::Error}: this says the test is wrong, not
    # that Zammad refused something, so a +rescue ZammadAPI::Error+ in the code
    # under test does not swallow it.
    class UnstubbedRequestError < StandardError; end

    # One request the code under test made.
    #
    # @!attribute [r] verb
    #   @return [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @!attribute [r] path
    #   @return [String] path relative to the instance URL
    # @!attribute [r] query
    #   @return [Hash{String => Object}] query parameters, with keys and
    #     values as text
    # @!attribute [r] body
    #   @return [Hash, nil] the request payload
    # @!attribute [r] headers
    #   @return [Hash{String => String}] the headers the call asked for, names
    #     downcased. The +From+ scope has a member of its own below.
    # @!attribute [r] on_behalf_of
    #   @return [String, nil] the +From+ scope in effect
    Request = Data.define(:verb, :path, :query, :body, :headers, :on_behalf_of)

    # @return [Config] the configuration the stand-in client reports
    attr_reader :config

    # A client that talks to this stand-in instead of to a Zammad.
    #
    # @return [Client]
    attr_reader :client

    # @param options [Hash] any option accepted by {Config}; the defaults are
    #   enough for a client that never opens a connection
    def initialize(**options)
      @config   = Config.new(**Config.merge_options({ url: 'https://zammad.test/', http_token: 'test-token' }, options))
      @stubs    = {}
      @requests = []
      @monitor  = Mutex.new
      @client   = Client.build(@config, Transport.new(self))
    end

    # Declares the response for one endpoint.
    #
    # Stubbing the same method and path again queues a second response: the
    # first request gets the first, and the last one answers every request
    # after it. A +query+ matches when every parameter it names is present in
    # the request with that value, so a stub does not have to repeat the
    # +expand+, +page+ and +per_page+ parameters the client adds itself.
    #
    # A list read asks for pages until one is short or empty. A stub whose
    # +query+ names no +page+ answers the first page, and every page after it
    # with an empty list.
    #
    # @param method [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @param path [String] path relative to the instance URL, leading slash
    #   optional
    # @param status [Integer] HTTP status to answer with
    # @param body [Hash, Array, String, nil] a Hash or Array is served as JSON,
    #   anything else as it is
    # @param headers [Hash] response headers; a Hash or Array body is given
    #   +content-type: application/json+ unless this says otherwise
    # @param query [Hash, nil] only answer requests carrying these parameters
    # @return [self]
    def stub(method, path, status: 200, body: nil, headers: {}, query: nil)
      headers = headers.to_h { |name, value| [name.to_s.downcase, value.to_s] }
      headers = { 'content-type' => 'application/json' }.merge(headers) if body.is_a?(Hash) || body.is_a?(Array)

      @monitor.synchronize do
        (@stubs[key(method, path)] ||= []) << { status: status, body: body, headers: headers.freeze, query: query && stringify(query) }
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
    def stubbed = @monitor.synchronize { stubbed_endpoints }

    def inspect = @monitor.synchronize { "#<#{self.class.name} stubbed=#{@stubs.size} requests=#{@requests.size}>" }

    # Answers a request from the stubs, recording it first. This is the
    # {Transport} interface, called by the client rather than by a test.
    #
    # @api private
    # @return [Response]
    # @raise [ResponseError] for a stubbed non-2xx status
    # @raise [UnstubbedRequestError] when no stub matches
    def answer(method, path, operation:, query: nil, body: nil, headers: nil, resource_class: nil, on_behalf_of: nil)
      relative = ::ZammadAPI::Transport.relative_path(path)
      params   = stringify(query || {})
      request  = Request.new(
        verb:         method,
        path:         relative,
        query:        params,
        body:         DeepCopy.frozen_copy(body),
        headers:      (headers || {}).to_h { |name, value| [name.to_s.downcase, value.to_s] },
        on_behalf_of: on_behalf_of
      )

      stub = @monitor.synchronize do
        @requests << request
        take(method, relative, params)
      end
      raise UnstubbedRequestError, unstubbed_message(request) if stub.nil?

      response = response_for(stub)
      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    end

    private

    def key(method, path) = [method.to_sym, ::ZammadAPI::Transport.relative_path(path)]

    def stringify(value)
      case value
      when Hash  then value.to_h { |name, nested| [name.to_s, stringify(nested)] }
      when Array then value.map { stringify(it) }
      else value.to_s
      end
    end

    # What a later page is answered with where the stub names no page.
    EMPTY_PAGE = { status: 200, body: [].freeze, headers: { 'content-type' => 'application/json' }.freeze, query: nil }.freeze
    private_constant :EMPTY_PAGE

    # The first stub of the endpoint whose query matches, spent unless it is
    # the last that does. A later page, where that stub names no page, is an
    # empty list and spends nothing.
    def take(method, path, params)
      queued   = @stubs[key(method, path)] || []
      matching = queued.each_index.select { |index| matches?(queued.fetch(index)[:query], params) }
      return nil if matching.empty?

      stub = queued.fetch(matching.first)

      return EMPTY_PAGE if !['1', nil].include?(params['page']) && !stub[:query]&.key?('page')

      queued.delete_at(matching.first) if matching.size > 1
      stub
    end

    def matches?(expected, params) = expected.nil? || expected.all? { |name, value| params[name] == value }

    def response_for(stub)
      raw = case stub[:body]
            when Hash, Array then JSON.generate(stub[:body])
            when nil         then ''
            else                  stub[:body].to_s
            end

      Response.new(status: stub[:status], headers: stub[:headers], body: Response.decode_body(stub[:headers]['content-type'], raw), raw_body: raw)
    end

    def stubbed_endpoints = @stubs.keys.map { |method, path| "#{method.to_s.upcase} #{path}" }

    def unstubbed_message(request)
      stubbed = @monitor.synchronize { stubbed_endpoints }

      "#{request.verb.to_s.upcase} #{request.path} with query #{request.query.inspect} was not stubbed on this " \
        "#{self.class.name} (#{stubbed.empty? ? 'nothing is stubbed' : "stubbed: #{stubbed.join(', ')}"})"
    end

    # The transport a {Test} client talks through.
    #
    # @api private
    class Transport
      include ::ZammadAPI::Transport::Verbs

      attr_reader :test, :config, :on_behalf_of

      # @param test [Test]
      # @param on_behalf_of [String, nil]
      # @param config [Config]
      def initialize(test, on_behalf_of: nil, config: test.config)
        @test         = test
        @config       = config
        @on_behalf_of = on_behalf_of
      end

      def with_on_behalf_of(identifier) = self.class.new(test, on_behalf_of: identifier, config: config)

      def with_config(config) = self.class.new(test, on_behalf_of: on_behalf_of, config: config)

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
