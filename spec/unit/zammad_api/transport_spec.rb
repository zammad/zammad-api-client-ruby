# frozen_string_literal: true

require 'pp'

RSpec.describe ZammadAPI::Transport do
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  describe 'authentication' do
    it 'sends a Token header for an access token' do
      stub = stub_request(:get, url).with(headers: { 'Authorization' => 'Token test-token' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'sends a Bearer header for an OAuth2 token' do
      stub = stub_request(:get, url).with(headers: { 'Authorization' => 'Bearer oauth' }).to_return(json_response([]))
      unit_transport(http_token: nil, oauth2_token: 'oauth').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'sends basic auth for user and password' do
      stub = stub_request(:get, url).with(basic_auth: %w[u p]).to_return(json_response([]))
      unit_transport(http_token: nil, user: 'u', password: 'p').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end
  end

  describe 'default headers' do
    it 'identifies the client' do
      stub = stub_request(:get, url)
        .with(headers: { 'User-Agent' => "zammad_api-ruby/#{ZammadAPI::VERSION}" })
        .to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'asks for JSON' do
      stub = stub_request(:get, url).with(headers: { 'Accept' => 'application/json' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'allows overriding the user agent' do
      stub = stub_request(:get, url).with(headers: { 'User-Agent' => 'my-app/1.0' }).to_return(json_response([]))
      unit_transport(user_agent: 'my-app/1.0').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'names itself where the user agent given is nothing but whitespace' do
      stub = stub_request(:get, url).with(headers: { 'User-Agent' => "zammad_api-ruby/#{ZammadAPI::VERSION}" }).to_return(json_response([]))
      unit_transport(user_agent: '  ').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    # WebMock is asked by Net::HTTP, which has stripped the headers by then.
    # A middleware sees them as the adapter is handed them.
    context 'with a configured header value that ends in a line break' do
      def handed_to_the_adapter(**options)
        seen     = nil
        recorder = Class.new(Faraday::Middleware) do
          define_method(:on_request) { |env| seen = env.request_headers.to_h }
        end
        stub_request(:get, url).to_return(json_response([]))
        unit_transport(middleware: ->(builder) { builder.use(recorder) }, **options).get('api/v1/groups', operation: 'test')
        seen
      end

      it 'hands the adapter an access token without it' do
        expect(handed_to_the_adapter(http_token: "abc\n")['Authorization']).to eq('Token abc')
      end

      it 'hands the adapter an OAuth2 token without it' do
        expect(handed_to_the_adapter(http_token: nil, oauth2_token: "abc\r\n")['Authorization']).to eq('Bearer abc')
      end

      it 'hands the adapter a user agent without it' do
        expect(handed_to_the_adapter(user_agent: "my-app/1.0\n")['User-Agent']).to eq('my-app/1.0')
      end
    end
  end

  describe 'request headers' do
    it 'sends the headers given for a request, each value as text' do
      stub = stub_request(:get, url).with(headers: { 'X-Trace' => 'abc', 'X-Count' => '2' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test', headers: { 'X-Trace' => 'abc', 'X-Count' => 2 })
      expect(stub).to have_been_requested
    end
  end

  describe 'base url handling' do
    it 'keeps a sub-path prefix in front of the request path' do
      stub = stub_request(:get, 'http://zammad.test/helpdesk/api/v1/groups').to_return(json_response([]))
      unit_transport(url: 'http://zammad.test/helpdesk').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end
  end

  describe 'query parameters' do
    it 'encodes scalars as strings' do
      stub = stub_request(:get, url).with(query: { 'page' => '1', 'expand' => 'true' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test', query: { page: 1, expand: true })
      expect(stub).to have_been_requested
    end

    it 'escapes values that need it' do
      stub = stub_request(:get, "#{url}/search").with(query: { 'query' => 'a b&c' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups/search', operation: 'test', query: { query: 'a b&c' })
      expect(stub).to have_been_requested
    end

    it 'encodes arrays' do
      stub = stub_request(:get, url).with(query: { 'ids' => %w[1 2] }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test', query: { ids: [1, 2] })
      expect(stub).to have_been_requested
    end

    # `condition` is what Zammad's search endpoints narrow by, and it is
    # nested.
    it 'encodes a nested hash the way Rails reads it back' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: { 'condition' => { 'ticket.state_id' => { 'operator' => 'is', 'value' => %w[1 2] } } })
        .to_return(json_response([]))
      unit_transport.get(
        'api/v1/groups/search',
        operation: 'test',
        query:     { condition: { 'ticket.state_id' => { operator: 'is', value: [1, 2] } } }
      )
      expect(stub).to have_been_requested
    end
  end

  describe '.relative_path' do
    it 'drops a leading slash' do
      expect(described_class.relative_path('/api/v1/tickets')).to eq('api/v1/tickets')
    end

    # Faraday would send the request, credentials and all, to that host.
    it 'refuses an absolute URL' do
      expect { described_class.relative_path('https://other.example/collect') }
        .to raise_error(ArgumentError, /this one is an absolute URL: pass the path alone/)
    end

    it 'makes no request for one' do
      expect { unit_transport.get('https://other.example/collect', operation: 'test') }.to raise_error(ArgumentError)
      expect(a_request(:any, //)).not_to have_been_made
    end
  end

  # The path is printed in the log, in the message of a timeout and in the
  # operation a raw request is named by, and a raw request may carry its
  # query in it.
  describe '.redact_path' do
    it 'leaves a path without a query as it is' do
      expect(described_class.redact_path('api/v1/tickets/1')).to eq('api/v1/tickets/1')
    end

    it 'drops a query string, which may carry a token' do
      expect(described_class.redact_path('api/v1/x?page=2&token=s3cret')).to eq('api/v1/x')
    end

    it 'drops a fragment' do
      expect(described_class.redact_path('api/v1/x#token=s3cret')).to eq('api/v1/x')
    end

    context 'when a raw request is written with a fragment' do
      let(:log) { StringIO.new }

      before { stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/x").to_return(json_response({}, status: 404)) }

      it 'keeps it out of the error the request raises' do
        expect { unit_client.get('api/v1/x#token=s3cret') }
          .to raise_error(ZammadAPI::NotFoundError) { |error|
            expect(error.message).not_to include('s3cret')
            expect(error.operation).to eq('GET api/v1/x')
          }
      end

      it 'keeps it out of the log' do
        expect { unit_client(logger: Logger.new(log)).get('api/v1/x#token=s3cret') }.to raise_error(ZammadAPI::NotFoundError)

        expect(log.string).to include("Zammad API request: GET api/v1/x\n")
        expect(log.string).not_to include('s3cret')
      end
    end
  end

  describe '.redact' do
    it 'blanks the value under a key that names a credential' do
      expect(described_class.redact({ login: 'x', password: 'hunter2' })).to eq({ login: 'x', password: '[REDACTED]' })
    end

    it 'reads a String key the way it reads a Symbol' do
      expect(described_class.redact({ 'api_key' => 'k' })).to eq({ 'api_key' => '[REDACTED]' })
    end

    it 'blanks one at any depth, through Hashes and Arrays' do
      expect(described_class.redact({ users: [{ preferences: { access_token: 't', locale: 'de' } }] }))
        .to eq({ users: [{ preferences: { access_token: '[REDACTED]', locale: 'de' } }] })
    end

    it 'blanks the whole of a structure held under such a key' do
      expect(described_class.redact({ tokens: [{ name: 'a' }] })).to eq({ tokens: '[REDACTED]' })
    end

    it 'leaves what it was given as it was' do
      attributes = { password: 'hunter2' }
      described_class.redact(attributes)

      expect(attributes).to eq({ password: 'hunter2' })
    end

    it 'hands back anything that is not a structure' do
      expect(described_class.redact('password')).to eq('password')
    end
  end

  describe '.escape_path_segment' do
    it 'leaves an ordinary id alone' do
      expect(described_class.escape_path_segment(42)).to eq('42')
    end

    it 'encodes a separator, so an id cannot walk out of its segment' do
      expect(described_class.escape_path_segment('1/../../api/v1/users/1'))
        .to eq('1%2F..%2F..%2Fapi%2Fv1%2Fusers%2F1')
    end

    it 'encodes a query and fragment marker' do
      expect(described_class.escape_path_segment('1?a=b#c')).to eq('1%3Fa%3Db%23c')
    end

    it 'encodes a multibyte character one byte at a time' do
      expect(described_class.escape_path_segment('ä')).to eq('%C3%A4')
    end

    it 'encodes a percent sign rather than passing an encoded id on' do
      expect(described_class.escape_path_segment('%2F')).to eq('%252F')
    end

    it 'takes a Symbol, for a member that is named rather than numbered' do
      expect(described_class.escape_path_segment(:me)).to eq('me')
    end

    it 'raises for an id with nothing to send' do
      expect { described_class.escape_path_segment('') }.to raise_error(ArgumentError, 'a record id is required')
    end

    it 'raises for nil' do
      expect { described_class.escape_path_segment(nil) }.to raise_error(ArgumentError, 'a record id is required')
    end
  end

  describe 'request bodies' do
    it 'sends JSON with the matching content type' do
      stub = stub_request(:post, url)
        .with(body: '{"name":"Support"}', headers: { 'Content-Type' => 'application/json' })
        .to_return(json_response({ id: 1 }, status: 201))
      unit_transport.post('api/v1/groups', operation: 'test', body: { name: 'Support' })
      expect(stub).to have_been_requested
    end

    it 'sends a body that is already a string as it is' do
      stub = stub_request(:post, url)
        .with(body: '{"name":"Raw"}', headers: { 'Content-Type' => 'application/json' })
        .to_return(json_response({ id: 1 }, status: 201))
      unit_transport.post('api/v1/groups', operation: 'test', body: '{"name":"Raw"}')
      expect(stub).to have_been_requested
    end

    context 'with values that are not JSON types' do
      before { stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201)) }

      it 'sends a Symbol as text' do
        unit_transport.post('api/v1/groups', operation: 'test', body: { state: :open, 1 => nil })

        expect(a_request(:post, url).with(body: '{"state":"open","1":null}')).to have_been_made
      end

      # Zammad reads a time or a date attribute from the text either prints.
      it 'sends a Time and a Date as they print' do
        unit_transport.post('api/v1/groups', operation: 'test', body: { pending_time: Time.utc(2026, 1, 2, 3, 4, 5), due: Date.new(2026, 1, 2) })

        expect(a_request(:post, url).with(body: '{"pending_time":"2026-01-02 03:04:05 UTC","due":"2026-01-02"}')).to have_been_made
      end

      it 'leaves an object with a to_json of its own to write itself' do
        point = Data.define(:x, :y) { def to_json(*) = to_h.to_json(*) }.new(1, 2)
        unit_transport.post('api/v1/groups', operation: 'test', body: { point: point, points: [point] })

        expect(a_request(:post, url).with(body: '{"point":{"x":1,"y":2},"points":[{"x":1,"y":2}]}')).to have_been_made
      end

      it 'sends a record of this gem as its attributes' do
        group = ZammadAPI::Resources::Group.from_response(unit_transport, { id: 1, name: 'Users' })
        unit_transport.post('api/v1/groups', operation: 'test', body: { group: group })

        expect(a_request(:post, url).with(body: '{"group":{"id":1,"name":"Users"}}')).to have_been_made
      end
    end
  end

  describe 'response decoding' do
    it 'decodes JSON with symbol keys' do
      stub_request(:get, url).to_return(json_response({ id: 1, nested: { a: 'b' } }))
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq({ id: 1, nested: { a: 'b' } })
    end

    it 'exposes the raw body as well' do
      stub_request(:get, url).to_return(json_response({ id: 1 }))
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.raw_body).to eq('{"id":1}')
    end

    it 'leaves non-JSON bodies untouched' do
      stub_request(:get, url).to_return(status: 200, body: 'plain text', headers: { 'Content-Type' => 'text/plain' })
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq('plain text')
    end

    it 'keeps a malformed JSON body as a string instead of raising' do
      stub_request(:get, url).to_return(status: 200, body: 'not json', headers: { 'Content-Type' => 'application/json' })
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq('not json')
    end

    it 'handles an empty body' do
      stub_request(:get, url).to_return(status: 200, body: '', headers: { 'Content-Type' => 'application/json' })
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq('')
    end

    it 'downcases header names' do
      stub_request(:get, url).to_return(json_response([], headers: { 'X-Request-Id' => 'abc' }))
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.headers['x-request-id']).to eq('abc')
    end
  end

  describe 'error responses' do
    it 'raises NotFoundError for 404' do
      stub_request(:get, url).to_return(json_response({ error: 'nope' }, status: 404))
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::NotFoundError, "Can't find object: nope")
    end

    it 'raises AuthenticationError for 401' do
      stub_request(:get, url).to_return(json_response({ error: 'authentication failed' }, status: 401))
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::AuthenticationError)
    end

    it 'raises ServerError with the status when a proxy returns HTML' do
      stub_request(:get, url).to_return(status: 502, body: '<html>Bad Gateway</html>', headers: { 'Content-Type' => 'text/html' })
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::ServerError, "Can't find object: HTTP 502")
    end

    it 'includes the resource class in the message' do
      stub_request(:get, url).to_return(json_response({ error: 'nope' }, status: 404))
      expect { unit_transport.get('api/v1/groups', operation: 'find object', resource_class: ZammadAPI::Resources::Group) }
        .to raise_error(/\(ZammadAPI::Resources::Group\)/)
    end
  end

  describe 'network failures' do
    it 'wraps a read timeout' do
      stub_request(:get, url).to_raise(Net::ReadTimeout)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError, %r{Can't find object: request to api/v1/groups timed out})
    end

    it 'keeps a query string written into the path out of the message' do
      stub_request(:get, url).with(query: hash_including({})).to_raise(Net::ReadTimeout)
      expect { unit_transport.get('api/v1/groups?token=path-s3cret', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError, %r{request to api/v1/groups timed out}) { |error| expect(error.message).not_to include('s3cret') }
    end

    # Net::HTTP raises Net::OpenTimeout for it, and the default adapter wraps
    # that into Faraday::ConnectionFailed with every other failure to connect.
    context 'when the connection is not established within open_timeout' do
      before { stub_request(:get, url).to_raise(Net::OpenTimeout.new('execution expired')) }

      it 'raises ConnectionError, as Faraday reports it' do
        expect { unit_transport.get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::ConnectionError, %r{Can't find object: http://zammad\.test/ is unreachable \(execution expired\)})
      end

      it 'is still retried, as a read that never reached the server' do
        expect { unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::ConnectionError)
        expect(a_request(:get, url)).to have_been_made.times(3)
      end
    end

    it 'wraps a refused connection' do
      stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::ConnectionError, /is unreachable/)
    end

    it 'wraps a TLS failure' do
      stub_request(:get, url).to_raise(OpenSSL::SSL::SSLError)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::ConnectionError, /TLS handshake/)
    end

    it 'names the instance it could not reach' do
      stub_request(:get, url).to_raise(Faraday::ConnectionFailed.new('down'))

      expect { unit_transport.get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError, %r{http://zammad\.test/ is unreachable})
    end

    it 'raises a TransportError subclass so both can be rescued together' do
      stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TransportError)
    end
  end

  describe 'retries' do
    it 'retries an idempotent request after a server error' do
      stub_request(:get, url).to_return({ status: 500 }, json_response([{ id: 1 }]))
      response = unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'test')
      expect(response.status).to eq(200)
    end

    it 'retries after a rate limit response' do
      stub_request(:get, url).to_return({ status: 429 }, json_response([]))
      response = unit_transport(retries: 1, retry_interval: 0.01).get('api/v1/groups', operation: 'test')
      expect(response.status).to eq(200)
    end

    # The retry middleware sleeps for whatever Retry-After says, up to a
    # ceiling that is set to the timeout.
    context 'when the server asks for a longer wait than the timeout' do
      let(:transport) { unit_transport(retries: 2, retry_interval: 0.01, timeout: 2) }

      before do
        stub_request(:get, url).to_return({ status: 429, headers: { 'Retry-After' => '3600' } }, json_response([]))
      end

      it 'reports the response instead of waiting it out' do
        expect { transport.get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::RateLimitError)
      end

      it 'does not retry' do
        expect { transport.get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::RateLimitError)
        expect(a_request(:get, url)).to have_been_made.once
      end

      it 'leaves the wait the server asked for readable from the error' do
        expect { transport.get('api/v1/groups', operation: 'test') }
          .to raise_error(ZammadAPI::RateLimitError) { |error| expect(error.retry_after).to eq(3600) }
      end
    end

    it 'does not wait out a long Retry-After on a 503 either' do
      stub_request(:get, url).to_return({ status: 503, headers: { 'Retry-After' => '3600' } }, json_response([]))

      expect { unit_transport(retries: 2, retry_interval: 0.01, timeout: 2).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:get, url)).to have_been_made.once
    end

    it 'still waits as long as the server asks, where that is within the timeout' do
      stub_request(:get, url).to_return({ status: 429, headers: { 'Retry-After' => '0.2' } }, json_response([]))

      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = unit_transport(retries: 1, retry_interval: 0.01).get('api/v1/groups', operation: 'test')

      expect(response.status).to eq(200)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.2
    end

    it 'gives up after the configured number of attempts' do
      stub_request(:get, url).to_return(status: 500)
      expect { unit_transport(retries: 1, retry_interval: 0.01).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:get, url)).to have_been_made.twice
    end

    it 'does not retry POST, which could duplicate records' do
      stub_request(:post, url).to_return(status: 500)
      expect { unit_transport(retries: 2, retry_interval: 0.01).post('api/v1/groups', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:post, url)).to have_been_made.once
    end

    # A ticket update carrying an article creates that article, and sends its
    # e-mail, on every delivery.
    it 'does not retry PUT, which Zammad does not always handle idempotently' do
      stub_request(:put, "#{url}/1").to_return({ status: 504 }, json_response({ id: 1 }))
      expect { unit_transport(retries: 2, retry_interval: 0.01).put('api/v1/groups/1', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:put, "#{url}/1")).to have_been_made.once
    end

    it 'does not retry PUT after a timeout either' do
      stub_request(:put, "#{url}/1").to_raise(Net::ReadTimeout).then.to_return(json_response({ id: 1 }))
      expect { unit_transport(retries: 2, retry_interval: 0.01).put('api/v1/groups/1', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::TimeoutError)
      expect(a_request(:put, "#{url}/1")).to have_been_made.once
    end

    # Repeated after a lost answer, a DELETE meets a 404 for the record it has
    # just deleted.
    it 'does not retry DELETE, which would answer a lost success with a 404' do
      stub_request(:delete, "#{url}/1").to_raise(Net::ReadTimeout).then.to_return(json_response({ error: 'gone' }, status: 404))
      expect { unit_transport(retries: 2, retry_interval: 0.01).delete('api/v1/groups/1', operation: 'test') }
        .to raise_error(ZammadAPI::TimeoutError)
      expect(a_request(:delete, "#{url}/1")).to have_been_made.once
    end

    it 'does not retry a client error' do
      stub_request(:get, url).to_return(json_response({ error: 'nope' }, status: 404))
      expect { unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::NotFoundError)
      expect(a_request(:get, url)).to have_been_made.once
    end
  end

  describe 'the Faraday seam' do
    it 'calls the middleware with the connection being built' do
      seen = nil
      unit_transport(middleware: ->(connection) { seen = connection })

      expect(seen).to be_a(Faraday::Connection)
    end

    it 'lets the middleware see a request this gem built' do
      stub_request(:get, url).to_return(json_response([]))

      seen = nil
      transport = unit_transport(middleware: lambda { |builder|
        builder.use(Class.new(Faraday::Middleware) do
          define_method(:on_request) { |env| seen = env.request_headers['User-Agent'] }
        end)
      })
      transport.get('api/v1/groups', operation: 'test')

      expect(seen).to eq("zammad_api-ruby/#{ZammadAPI::VERSION}")
    end

    it 'lets the middleware see the response' do
      stub_request(:get, url).to_return(json_response([{ id: 1 }]))

      seen = nil
      transport = unit_transport(middleware: lambda { |builder|
        builder.use(Class.new(Faraday::Middleware) do
          define_method(:on_complete) { |env| seen = env.status }
        end)
      })
      transport.get('api/v1/groups', operation: 'test')

      expect(seen).to eq(200)
    end

    it 'leaves a middleware that does not touch the body alone' do
      stub_request(:get, url).to_return(json_response([{ id: 1, name: 'Users' }]))

      response = unit_transport(middleware: ->(builder) { builder.response(:logger, Logger.new(File::NULL)) })
        .get('api/v1/groups', operation: 'test')

      expect(response.body).to eq([{ id: 1, name: 'Users' }])
    end

    it 'uses the configured adapter' do
      transport = unit_transport(adapter: :test)
      expect(transport.instance_variable_get(:@connection).adapter.name).to include('Adapter::Test')
    end

    # The callable runs after the adapter option is applied, and setting an
    # adapter replaces the one that is there.
    context 'with an adapter chosen inside the middleware callable' do
      let(:stubs) { Faraday::Adapter::Test::Stubs.new { it.get('/api/v1/groups') { [200, { 'Content-Type' => 'application/json' }, '[{"id":7}]'] } } }

      it 'keeps it' do
        transport = unit_transport(middleware: ->(faraday) { faraday.adapter :test, stubs })

        expect(transport.instance_variable_get(:@connection).adapter.name).to include('Adapter::Test')
      end

      it 'sends requests through it, with the arguments it was given' do
        transport = unit_transport(middleware: ->(faraday) { faraday.adapter :test, stubs })

        expect(transport.get('api/v1/groups', operation: 'test').body).to eq([{ id: 7 }])
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'keeps it where it is the default adapter, named again to give it a block' do
        configured = nil
        transport  = unit_transport(middleware: ->(faraday) { faraday.adapter(Faraday.default_adapter) { configured = true } })
        stub_request(:get, url).to_return(json_response([]))
        transport.get('api/v1/groups', operation: 'test')

        expect(configured).to be(true)
      end

      it 'takes it over the one the adapter option names' do
        transport = unit_transport(adapter: :net_http, middleware: ->(faraday) { faraday.adapter :test, stubs })

        expect(transport.get('api/v1/groups', operation: 'test').body).to eq([{ id: 7 }])
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'still puts the default adapter in where the callable chose none' do
        transport = unit_transport(middleware: ->(faraday) { faraday.use(Class.new(Faraday::Middleware)) })

        expect(transport.instance_variable_get(:@connection).adapter.name).to eq(Faraday::Adapter.lookup_middleware(Faraday.default_adapter).name)
      end
    end

    it 'reports an unregistered adapter as a configuration error' do
      expect { unit_transport(adapter: :nonsense) }
        .to raise_error(ZammadAPI::ConfigurationError, /\Aconfig could not be used to build a connection: .*is not registered on Faraday::Adapter/)
    end

    it 'does not leak a Faraday error out of the client constructor' do
      expect { unit_client(adapter: :nonsense) }.to raise_error(ZammadAPI::ConfigurationError)
    end

    it 'keeps the cause of an unregistered adapter' do
      expect { unit_transport(adapter: :nonsense) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be_a(Faraday::Error) }
    end
  end

  describe '#with_on_behalf_of' do
    it 'sends the From header' do
      stub = stub_request(:get, url).with(headers: { 'From' => 'agent@example.com' }).to_return(json_response([]))
      unit_transport.with_on_behalf_of('agent@example.com').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'keeps an unscoped transport unscoped' do
      expect(unit_transport.with_on_behalf_of(nil).on_behalf_of).to be_nil
    end

    it 'returns a different transport' do
      transport = unit_transport
      expect(transport.with_on_behalf_of('someone')).not_to be(transport)
    end

    it 'leaves the original transport unscoped' do
      transport = unit_transport
      transport.with_on_behalf_of('someone')
      expect(transport.on_behalf_of).to be_nil
    end

    it 'does not send a From header from the original transport' do
      transport = unit_transport
      transport.with_on_behalf_of('someone')

      stub_request(:get, url).to_return(json_response([]))
      transport.get('api/v1/groups', operation: 'test')

      expect(a_request(:get, url).with { |request| request.headers.key?('From') }).not_to have_been_made
    end

    it 'shares the underlying connection instead of rebuilding it' do
      transport = unit_transport
      scoped    = transport.with_on_behalf_of('someone')
      expect(scoped.instance_variable_get(:@connection)).to be(transport.instance_variable_get(:@connection))
    end
  end

  # Left to Ruby, inspect would print the Faraday connection, whose proxy
  # options carry the proxy password and whose middleware stack carries the
  # token it was built with.
  describe '#inspect' do
    let(:transport) do
      unit_transport(http_token: 'tok-s3cret', proxy: 'http://puser:pproxy-s3cret@proxy.test:8080')
    end

    it 'names the instance and the authentication scheme' do
      expect(unit_transport.inspect).to eq('#<ZammadAPI::Transport url="http://zammad.test/" auth=http_token>')
    end

    it 'names an on_behalf_of scope' do
      expect(unit_transport.with_on_behalf_of('agent@example.com').inspect).to include('on_behalf_of="agent@example.com"')
    end

    it 'does not print the access token' do
      expect(transport.inspect).not_to include('tok-s3cret')
    end

    it 'does not print the proxy password' do
      expect(transport.inspect).not_to include('pproxy-s3cret')
    end

    it 'does not print a basic authentication password' do
      basic = unit_transport(http_token: nil, user: 'u', password: 'pw-s3cret')
      expect(basic.inspect).not_to include('pw-s3cret')
    end

    it 'keeps both out of what pp prints too' do
      expect(transport.pretty_inspect).not_to match(/tok-s3cret|pproxy-s3cret/)
    end
  end

  describe '#with_config' do
    it 'applies the new configuration' do
      expect(unit_transport.with_config(ZammadAPI::Config.new(**unit_config(timeout: 7))).config.timeout).to eq(7)
    end

    it 'carries the on_behalf_of scope over' do
      derived = unit_transport.with_on_behalf_of('agent@example.com')
        .with_config(ZammadAPI::Config.new(**unit_config(timeout: 7)))

      expect(derived.on_behalf_of).to eq('agent@example.com')
    end

    it 'keeps a subclass on its own kind, rather than reverting to a real one' do
      recording = Class.new(described_class)
      stub_const('RecordingTransport', recording)

      derived = recording.new(ZammadAPI::Config.new(**unit_config)).with_config(ZammadAPI::Config.new(**unit_config(timeout: 7)))

      expect(derived).to be_a(recording)
    end

    it 'returns a different transport' do
      transport = unit_transport
      expect(transport.with_config(transport.config)).not_to be(transport)
    end
  end

  describe 'logging' do
    subject(:log) { log_device.string }

    let(:log_device) { StringIO.new }
    let(:logger) { Logger.new(log_device, level: Logger::DEBUG) }

    before do
      stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201))
      unit_transport(logger: logger, user: 'u', password: 'pw-s3cret', http_token: nil)
        .post('api/v1/groups', operation: 'test', body: { login: 'jane', password: 'pw-s3cret' })
    end

    it 'logs the request' do
      expect(log).to include('Zammad API request: POST api/v1/groups')
    end

    it 'logs the response status' do
      expect(log).to include('Zammad API response: POST api/v1/groups -> 201')
    end

    it 'never logs a password from the payload' do
      expect(log).not_to include('pw-s3cret')
    end

    it 'marks the redacted payload value' do
      expect(log).to include('password: "[REDACTED]"')
    end

    it 'keeps non-sensitive payload values' do
      expect(log).to include('login: "jane"')
    end

    it 'stays silent by default' do
      stub_request(:get, url).to_return(json_response([]))

      expect { unit_transport.get('api/v1/groups', operation: 'test') }
        .to output('').to_stdout.and output('').to_stderr
    end

    context 'with credential-bearing payload keys' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }

      before do
        stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201))
        unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)).post(
          'api/v1/groups',
          operation: 'test',
          body:      {
            login:            'jane',
            password_confirm: 'confirm-s3cret',
            passwd:           'passwd-s3cret',
            access_token:     'access-s3cret',
            refresh_token:    'refresh-s3cret',
            client_secret:    'client-s3cret',
            api_key:          'api-key-s3cret',
            apikey:           'apikey-s3cret',
            key:              'key-s3cret'
          }
        )
      end

      it 'redacts a password_confirm' do
        expect(log).not_to include('confirm-s3cret')
      end

      it 'redacts an access_token' do
        expect(log).not_to include('access-s3cret')
      end

      it 'redacts a refresh_token' do
        expect(log).not_to include('refresh-s3cret')
      end

      it 'redacts an api_key' do
        expect(log).not_to include('api-key-s3cret')
      end

      it 'redacts an apikey, which nothing separates the word in' do
        expect(log).not_to include('apikey-s3cret')
      end

      it 'redacts a bare key' do
        expect(log).not_to include('key-s3cret')
      end

      it 'redacts a passwd' do
        expect(log).not_to include('passwd-s3cret')
      end

      it 'redacts a client_secret' do
        expect(log).not_to include('client-s3cret')
      end

      it 'still keeps a non-sensitive value' do
        expect(log).to include('login: "jane"')
      end
    end

    # The names Zammad filters from its own log, in
    # config/initializers/filter_parameter_logging.rb.
    describe 'the keys Zammad filters from its own log' do
      %w[bind_pw passphrase privateKey sshKeys publicKeyId otp otp_code totp hotp salt pw_salt].each do |name|
        it "redacts #{name}" do
          expect(described_class.redact({ name => 's3cret' })).to eq({ name => '[REDACTED]' })
        end
      end

      it 'leaves bind_user alone' do
        expect(described_class.redact({ 'bind_user' => 'shown' })).to eq({ 'bind_user' => 'shown' })
      end

      it 'redacts a bind password inside the preferences of an LDAP source' do
        expect(described_class.redact({ name: 'x', preferences: { bind_user: 'cn=admin', bind_pw: 'hunter2' } }))
          .to eq({ name: 'x', preferences: { bind_user: 'cn=admin', bind_pw: '[REDACTED]' } })
      end
    end

    # Redaction goes by key, and a String has none.
    context 'with a body handed over as a String' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }
      let(:transport)  { unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)) }

      before { stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201)) }

      it 'does not log it, and says how much was left out' do
        transport.post('api/v1/groups', operation: 'test', body: '{"login":"jane","password":"string-s3cret"}')

        expect(log).not_to include('string-s3cret')
        expect(log).to include('Zammad API payload: [43 bytes, not logged]')
      end

      it 'still sends the body as it was given' do
        transport.post('api/v1/groups', operation: 'test', body: '{"login":"jane","password":"string-s3cret"}')

        expect(a_request(:post, url).with(body: '{"login":"jane","password":"string-s3cret"}')).to have_been_made
      end
    end

    context 'with a query that carries a credential' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }
      let(:transport)  { unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)) }

      before { stub_request(:get, url).with(query: hash_including({})).to_return(json_response([])) }

      it 'redacts it by key' do
        transport.get('api/v1/groups', operation: 'test', query: { page: 1, token: 'query-s3cret' })

        expect(log).to include('Zammad API request: GET api/v1/groups query={page: 1, token: "[REDACTED]"}')
      end
    end

    # A raw request may carry its query in the path, where there is no key
    # to redact it by.
    context 'with a query string written into the path' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }
      let(:verify)     { 'api/v1/users/password_reset_verify?token=path-s3cret&locale=de' }

      before do
        stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/password_reset_verify").with(query: hash_including({})).to_return(json_response({}))
        unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)).get(verify, operation: 'test')
      end

      it 'keeps the credential in it out of the log' do
        expect(log).not_to include('path-s3cret')
      end

      it 'logs the request line without it' do
        expect(log).to include("Zammad API request: GET api/v1/users/password_reset_verify\n")
      end

      it 'logs the response line without it' do
        expect(log).to include('Zammad API response: GET api/v1/users/password_reset_verify -> 200')
      end

      it 'still sends the query as it was given' do
        expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/password_reset_verify").with(query: { 'token' => 'path-s3cret', 'locale' => 'de' }))
          .to have_been_made
      end
    end

    # A raw request takes headers of its own and the request line prints them.
    context 'with credential-bearing headers' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }

      before do
        stub_request(:get, url).to_return(json_response([]))
        unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)).get(
          'api/v1/groups',
          operation: 'test',
          headers:   {
            'Cookie'              => '_zammad_session=cookie-s3cret',
            'Proxy-Authorization' => 'Basic proxy-s3cret',
            'X-CSRF-Token'        => 'csrf-s3cret',
            'X-Request-Id'        => 'request-123'
          }
        )
      end

      it 'redacts a Cookie' do
        expect(log).not_to include('cookie-s3cret')
      end

      it 'marks the redacted header' do
        expect(log).to include('"Cookie" => "[REDACTED]"')
      end

      it 'redacts a Proxy-Authorization' do
        expect(log).not_to include('proxy-s3cret')
      end

      it 'redacts a token header' do
        expect(log).not_to include('csrf-s3cret')
      end

      it 'keeps a header that carries no credential' do
        expect(log).to include('"X-Request-Id" => "request-123"')
      end

      it 'still sends the headers as they were given' do
        expect(a_request(:get, url).with(headers: { 'Cookie' => '_zammad_session=cookie-s3cret', 'Proxy-Authorization' => 'Basic proxy-s3cret' }))
          .to have_been_made
      end
    end
  end
end
