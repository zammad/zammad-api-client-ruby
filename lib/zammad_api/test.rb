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
    class UnstubbedRequestError < Error; end

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
    #   @return [Hash] query parameters, as the client sent them
    # @!attribute [r] body
    #   @return [Hash, nil] the request payload
    # @!attribute [r] on_behalf_of
    #   @return [String, Integer, nil] the +From+ scope in effect
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
    end

    # A client that talks to this stand-in instead of to a Zammad.
    #
    # @return [Client]
    def client = Client.new(**@config.to_h.compact).with_transport(@transport)

    # Declares the response for one endpoint.
    #
    # Stubbing the same method and path again queues a second response: the
    # first request gets the first, and the last stub answers every request
    # after it. A +query+ matches when every parameter it names is present in
    # the request with that value, so a stub does not have to repeat the
    # +expand+, +page+ and +per_page+ parameters the client adds itself.
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
      @monitor.synchronize do
        (@stubs[key(method, path)] ||= []) << {
          status:  status,
          body:    body,
          headers: headers.to_h { |name, value| [name.to_s.downcase, value] },
          query:   query
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

    def inspect = "#<#{self.class.name} stubbed=#{stubbed.size} requests=#{@requests.size}>"

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
      params   = (query || {}).to_h { |name, value| [name.to_s, value] }

      stub = @monitor.synchronize do
        @requests << Request.new(verb: method, path: relative, query: params, body: body, on_behalf_of: on_behalf_of)
        take(method, relative, params)
      end

      raise UnstubbedRequestError, unstubbed_message(method, relative) if stub.nil?

      response = response_for(stub)
      return response if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    end

    private

    def key(method, path) = [method.to_sym, path.to_s.sub(%r{\A/+}, '')]

    # Keeps the last stub in place, so one stub can answer any number of
    # requests while two describe a sequence.
    def take(method, path, params)
      queued = @stubs[key(method, path)]
      return nil if queued.nil?

      index = queued.index { |stub| matches?(stub[:query], params) }
      return nil if index.nil?

      index == queued.size - 1 ? queued[index] : queued.delete_at(index)
    end

    def matches?(expected, params)
      return true if expected.nil?

      expected.all? { |name, value| params[name.to_s].to_s == value.to_s }
    end

    def response_for(stub)
      case stub[:body]
      in Hash | Array => structured
        raw = JSON.generate(structured)
        build_response(stub, JSON.parse(raw, symbolize_names: true), raw)
      in nil
        build_response(stub, '', '')
      in other
        # One object for both, so Response#json? reports false the way it does
        # for a real non-JSON response.
        raw = other.to_s
        build_response(stub, raw, raw)
      end
    end

    def build_response(stub, body, raw_body)
      Response.new(status: stub[:status], headers: stub[:headers], body: body, raw_body: raw_body)
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

      def with_on_behalf_of(identifier) = self.class.new(test, on_behalf_of: identifier)

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
