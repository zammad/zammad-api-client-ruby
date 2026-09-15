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

    # `condition` is what Zammad's search endpoints narrow by, and it is
    # nested. Rendered with to_s it went out as a Ruby inspect string, which
    # Zammad dropped, answering an unnarrowed search.
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

    it 'stringifies the scalars inside a nested hash' do
      expect(described_class.stringify_query(condition: { open: { active: true, limit: 5 } }))
        .to eq({ 'condition' => { 'open' => { 'active' => 'true', 'limit' => '5' } } })
    end

    it 'raises on a nil value rather than dropping the parameter' do
      expect { unit_transport.get('api/v1/groups', operation: 'test', query: { page: 1, note: nil }) }
        .to raise_error(ArgumentError, /query parameter note is nil/)
    end

    it 'names the path to a nil buried in a nested value' do
      expect { described_class.stringify_query(condition: { state: { value: nil } }) }
        .to raise_error(ArgumentError, /query parameter condition\[state\]\[value\] is nil/)
    end

    it 'names the index of a nil inside an array' do
      expect { described_class.stringify_query(ids: [1, nil]) }
        .to raise_error(ArgumentError, /query parameter ids\[1\] is nil/)
    end

    it 'makes no request for a query it rejects' do
      stub = stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect { unit_transport.get('api/v1/groups', operation: 'test', query: { note: nil }) }
        .to raise_error(ArgumentError)
      expect(stub).not_to have_been_requested
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

    it 'raises for an id with nothing to send' do
      expect { described_class.escape_path_segment('') }.to raise_error(ArgumentError, /record id is required/)
    end

    it 'raises for a parent dot segment, which the unreserved set would carry through' do
      expect { described_class.escape_path_segment('..') }.to raise_error(ArgumentError, /points at another endpoint/)
    end

    it 'raises for a current-directory dot segment' do
      expect { described_class.escape_path_segment('.') }.to raise_error(ArgumentError, /points at another endpoint/)
    end

    it 'leaves an id that merely starts with dots alone' do
      expect(described_class.escape_path_segment('..1')).to eq('..1')
    end

    it 'encodes an already-encoded dot segment rather than passing it on' do
      expect(described_class.escape_path_segment('%2e%2e')).to eq('%252e%252e')
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

    it 'does not leak credentials from the url into the message' do
      transport = unit_transport(url: 'https://admin:url-s3cret@zammad.test/')
      stub_request(:get, /zammad\.test/).to_raise(Faraday::ConnectionFailed.new('down'))

      expect { transport.get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError) { |error| expect(error.message).not_to include('url-s3cret') }
    end

    context 'with an adapter that does not wrap socket errors' do
      # The middleware seam raises from inside the stack, past the point where
      # an adapter would normally translate the error into a Faraday one.
      def raising(error)
        unit_transport(middleware: lambda { |faraday|
          faraday.use(Class.new(Faraday::Middleware) { define_method(:call) { |_env| raise error } })
        })
      end

      it 'wraps a bare Errno::ETIMEDOUT' do
        expect { raising(Errno::ETIMEDOUT).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError, /timed out/)
      end

      it 'wraps a bare Timeout::Error' do
        expect { raising(Timeout::Error).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError)
      end

      it 'wraps a bare Errno::ECONNREFUSED' do
        expect { raising(Errno::ECONNREFUSED).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::ConnectionError, /is unreachable/)
      end

      it 'wraps a SocketError' do
        expect { raising(SocketError).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::ConnectionError)
      end

      it 'leaves an unrelated Errno alone rather than calling it a network problem' do
        expect { raising(Errno::ENOSPC).get('api/v1/groups', operation: 'find object') }
          .to raise_error(Errno::ENOSPC)
      end
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

  # Most adapters wrap a socket failure into Faraday::ConnectionFailed, which
  # was retried; the same failure raw was not, so how often a request was
  # retried depended on which adapter the caller picked - through an option
  # this gem offers.
  describe 'retries through an adapter that does not wrap socket errors' do
    before { BareSocketAdapter.attempts = [] }

    def bare_socket_transport(**overrides)
      unit_transport(adapter: :bare_socket, retry_interval: 0.01, **overrides)
    end

    it 'retries an unwrapped socket error as often as a wrapped one' do
      expect { bare_socket_transport(retries: 2).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError)
      expect(BareSocketAdapter.attempts.size).to eq(3)
    end

    it 'still maps it to ConnectionError once the retries are spent' do
      expect { bare_socket_transport(retries: 1).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError, /is unreachable/)
    end

    it 'does not repeat a POST, which could duplicate records' do
      expect { bare_socket_transport(retries: 2).post('api/v1/groups', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::ConnectionError)
      expect(BareSocketAdapter.attempts).to eq([:post])
    end

    it 'retries every socket failure it maps to ConnectionError' do
      expect(described_class::RETRIABLE_EXCEPTIONS).to include(*described_class::CONNECTION_ERRORS)
    end

    it 'retries every socket failure it maps to TimeoutError' do
      expect(described_class::RETRIABLE_EXCEPTIONS).to include(*described_class::TIMEOUT_ERRORS)
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

    it 'uses the configured adapter' do
      transport = unit_transport(adapter: :test)
      expect(transport.instance_variable_get(:@connection).adapter.name).to include('Adapter::Test')
    end

    it 'reports an unregistered adapter as a configuration error' do
      expect { unit_transport(adapter: :nonsense) }
        .to raise_error(ZammadAPI::ConfigurationError, /is not registered on Faraday::Adapter/)
    end

    it 'does not leak a Faraday error out of the client constructor' do
      expect { unit_client(adapter: :nonsense) }.to raise_error(ZammadAPI::ConfigurationError)
    end

    # Only Faraday::Error used to be wrapped, so the failures that do not come
    # from Faraday - the ones a caller is least equipped to place - escaped
    # raw, past the `rescue ZammadAPI::ConfigurationError` the constructor is
    # documented to need.
    it 'reports a proxy that is not a url as a configuration error' do
      expect { unit_transport(proxy: 'http://user:pa ss@host') }
        .to raise_error(ZammadAPI::ConfigurationError, /URI::InvalidURIError/)
    end

    it 'reports a middleware that raises as a configuration error' do
      expect { unit_transport(middleware: ->(_) { raise NameError, 'boom' }) }
        .to raise_error(ZammadAPI::ConfigurationError, /NameError: boom/)
    end

    it 'does not relabel an error this gem raised itself' do
      failure = ZammadAPI::NotFoundError.new(operation: 'test', resource_class: nil, detail: 'gone')

      expect { unit_transport(middleware: ->(_) { raise failure }) }
        .to raise_error(ZammadAPI::NotFoundError)
    end
  end

  describe '#with_on_behalf_of' do
    it 'sends the From header' do
      stub = stub_request(:get, url).with(headers: { 'From' => 'agent@example.com' }).to_return(json_response([]))
      unit_transport.with_on_behalf_of('agent@example.com').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'sends an integer user id, which Net::HTTP will not stringify itself' do
      stub = stub_request(:get, url).with(headers: { 'From' => '42' }).to_return(json_response([]))
      unit_transport.with_on_behalf_of(42).get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'records the scope as the string the header carries' do
      expect(unit_transport.with_on_behalf_of(42).on_behalf_of).to eq('42')
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
            keyboard_layout:  'de',
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

      # Matched as a word, so that a key merely containing the letters stays
      # readable in the log rather than being blanked for nothing.
      it 'leaves a key whose name only contains one of the words alone' do
        expect(log).to include('keyboard_layout: "de"')
      end

      it 'redacts a client_secret' do
        expect(log).not_to include('client-s3cret')
      end

      it 'still keeps a non-sensitive value' do
        expect(log).to include('login: "jane"')
      end
    end
  end
end
