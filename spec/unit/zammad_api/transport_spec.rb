# frozen_string_literal: true

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

    it 'omits nil values' do
      stub = stub_request(:get, url).with(query: { 'page' => '1' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test', query: { page: 1, note: nil })
      expect(stub).to have_been_requested
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

    it 'does not retry a client error' do
      stub_request(:get, url).to_return(json_response({ error: 'nope' }, status: 404))
      expect { unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::NotFoundError)
      expect(a_request(:get, url)).to have_been_made.once
    end
  end

  describe '#with_on_behalf_of' do
    it 'sends the From header' do
      stub = stub_request(:get, url).with(headers: { 'From' => 'agent@example.com' }).to_return(json_response([]))
      unit_transport.with_on_behalf_of('agent@example.com').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
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

  describe 'logging' do
    subject(:log) { output.string }

    let(:output) { StringIO.new }
    let(:logger) { Logger.new(output, level: Logger::DEBUG) }

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
      quiet = StringIO.new
      allow(quiet).to receive(:write)
      stub_request(:get, url).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test')
      expect(quiet).not_to have_received(:write)
    end
  end
end
