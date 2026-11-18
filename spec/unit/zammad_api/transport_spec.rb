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
        .to raise_error(ArgumentError, /parameter condition\[state\]\[value\] is nil/)
    end

    it 'refuses two spellings of one parameter rather than sending whichever came last' do
      expect { described_class.stringify_query(state_id: 1, 'state_id' => 2) }
        .to raise_error(ArgumentError, /parameter state_id was given twice/)
    end

    it 'refuses the collision whichever order it arrives in' do
      expect { described_class.stringify_query('state_id' => 2, state_id: 1) }
        .to raise_error(ArgumentError, /parameter state_id was given twice/)
    end

    it 'names both spellings, so the caller does not have to guess the other' do
      expect { described_class.stringify_query(state_id: 1, 'state_id' => 2) }
        .to raise_error(ArgumentError, /as :state_id and as "state_id"/)
    end

    # `condition` is a Hash the search endpoints read, and two spellings inside
    # it collapsed exactly the way two at the top level did.
    it 'refuses a collision nested inside a structured parameter' do
      expect { described_class.stringify_query(condition: { 'state_id' => 1, state_id: 2 }) }
        .to raise_error(ArgumentError, /parameter condition\[state_id\] was given twice/)
    end

    it 'still sends a structured parameter whose keys only look alike' do
      expect(described_class.stringify_query(condition: { 'ticket.state_id' => { operator: 'is' } }))
        .to eq({ 'condition' => { 'ticket.state_id' => { 'operator' => 'is' } } })
    end

    it 'still accepts two parameters that only look alike' do
      expect(described_class.stringify_query(state_id: 1, state_ids: [2]))
        .to eq({ 'state_id' => '1', 'state_ids' => ['2'] })
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

    it 'sends a body that is already a string as it is' do
      stub = stub_request(:post, url)
        .with(body: '{"name":"Raw"}', headers: { 'Content-Type' => 'application/json' })
        .to_return(json_response({ id: 1 }, status: 201))
      unit_transport.post('api/v1/groups', operation: 'test', body: '{"name":"Raw"}')
      expect(stub).to have_been_requested
    end

    # Faraday's JSON middleware raised JSON::GeneratorError from inside the
    # stack and nothing mapped it, so it went past the rescue of
    # ZammadAPI::Error every caller is told to write.
    context 'with a body that cannot be encoded as JSON' do
      let(:binary) { { data: "\xFF\xD8\xFF".b } }

      it 'raises a ZammadAPI::Error for bytes that are not text' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary) }
          .to raise_error(ZammadAPI::Error, /Can't save object: the request body cannot be encoded as JSON/)
      end

      it 'raises a ZammadAPI::Error for a Float that JSON has no spelling for' do
        expect { unit_transport.put('api/v1/groups/1', operation: 'save object', body: { weight: Float::NAN }) }
          .to raise_error(ZammadAPI::Error, /NaN not allowed in JSON/)
      end

      it 'says what to do about binary data' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary) }
          .to raise_error(ZammadAPI::Error, /Base64-encode binary data/)
      end

      it 'names the resource it was sending' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary, resource_class: ZammadAPI::Resources::Group) }
          .to raise_error(ZammadAPI::Error, /save object \(ZammadAPI::Resources::Group\)/)
      end

      it 'makes no request' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary) }.to raise_error(ZammadAPI::Error)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'leaves no log line claiming a request that was never made' do
        log = StringIO.new
        expect { unit_transport(logger: Logger.new(log)).post('api/v1/groups', operation: 'save object', body: binary) }
          .to raise_error(ZammadAPI::Error)
        expect(log.string).to be_empty
      end

      it 'is raised by a record save carrying such a value' do
        group = unit_client.groups.new(name: 'Support', weight: Float::INFINITY)
        expect { group.save }.to raise_error(ZammadAPI::Error, /Infinity not allowed in JSON/)
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

    # Net::HTTP raises Net::OpenTimeout for it, and the default adapter wraps
    # that into Faraday::ConnectionFailed with every other failure to connect,
    # so it was reported as an unreachable host and skipped the rescue that is
    # documented to catch it.
    context 'when the connection is not established within open_timeout' do
      before { stub_request(:get, url).to_raise(Net::OpenTimeout.new('execution expired')) }

      it 'raises TimeoutError, not ConnectionError' do
        expect { unit_transport.get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError)
      end

      it 'says it was the connection that timed out' do
        expect { unit_transport.get('api/v1/groups', operation: 'find object') }
          .to raise_error(%r{Can't find object: connecting to http://zammad\.test/ timed out \(execution expired\)})
      end

      it 'is still retried, as a read that never reached the server' do
        expect { unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError)
        expect(a_request(:get, url)).to have_been_made.times(3)
      end
    end

    it 'reports the timeout WebMock simulates as one' do
      stub_request(:get, url).to_timeout
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError)
    end

    it 'reads a timeout out of a connection failure that only wraps one' do
      stub_request(:get, url).to_raise(Faraday::ConnectionFailed.new(Errno::ETIMEDOUT.new))
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError, /connecting to/)
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

    # The retry middleware sleeps for whatever Retry-After says, and its own
    # ceiling defaults to none: this held the calling thread for an hour per
    # retry before raising the error it could have raised at once.
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

    # A ticket update carrying an article creates that article on every
    # delivery, so repeating it sent the article - and its e-mail - twice.
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

    # Repeated after a lost answer, the second DELETE met a 404 and reported a
    # record that had just been deleted as one that could not be found.
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

    # `c.response :json` is a reasonable thing to put through a documented
    # seam, and Faraday then hands over a Hash rather than the bytes. `to_s`
    # turned that into a Ruby inspect string, which JSON.parse refused, so
    # every record built from the response died in Response#decoded with a
    # ParseError naming Zammad for what the caller's own stack had done.
    #
    # Re-encoding the parsed structure was the other way out, and it is worse:
    # `raw_body` is what an attachment download hands back as the file, so a
    # re-encoding returns something Zammad never stored. The bytes are gone
    # either way, so this names the cause while it is still visible.
    context 'with middleware that decodes the body first' do
      it 'refuses it when the stack is built, before anything is sent' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /decodes the response body before this gem can/)
      end

      it 'names the middleware it found' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /Faraday::Response::Json/)
      end

      it 'says which middleware to drop' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /c\.response :json/)
      end

      it 'is catchable as the gem error every caller rescues' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }.to raise_error(ZammadAPI::Error)
      end

      # The check used to live in `decode`, which is one request too late: the
      # POST went out, Zammad created the record, and only then did a
      # "configuration" error come back - so a caller retrying it made a second.
      it 'sends nothing before refusing' do
        stub = stub_request(:post, url).with(query: hash_including({}))

        expect { unit_client(middleware: ->(builder) { builder.response(:json) }).groups.create(name: 'X') }
          .to raise_error(ZammadAPI::ConfigurationError)
        expect(stub).not_to have_been_requested
      end
    end

    # The build-time check knows `Faraday::Response::Json` by name; anything
    # else that consumes the body is caught only once a response is in hand.
    context 'with a decoder the build-time check does not know by name' do
      subject(:transport) do
        unit_transport(middleware: lambda { |builder|
          builder.use(Class.new(Faraday::Middleware) do
            def on_complete(env) = env.body = { id: 1 }
          end)
        })
      end

      before { stub_request(:get, url).to_return(json_response([{ id: 1 }])) }

      it 'builds, because nothing named is in the stack' do
        expect { transport }.not_to raise_error
      end

      it 'refuses the response rather than stringifying what it got' do
        expect { transport.get('api/v1/groups', operation: 'test') }
          .to raise_error(ZammadAPI::ConfigurationError, /decoded the response body before this gem could/)
      end

      it 'names what it was handed instead of the body' do
        expect { transport.get('api/v1/groups', operation: 'test') }
          .to raise_error(ZammadAPI::ConfigurationError, /Faraday handed over Hash rather than the raw body/)
      end
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

    # The backtrace into the caller's own code is the one thing the message
    # cannot carry, so the cause stays wherever it gives nothing away.
    it 'keeps the error a middleware raised as the cause' do
      failure = NameError.new('boom')

      expect { unit_transport(middleware: ->(_) { raise failure }) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be(failure) }
    end

    # The middleware is on a line of its own on purpose. A NameError's report
    # quotes the source line it was raised on, so with the proxy written on
    # that line the report would carry the password after all - and the cause
    # would be dropped, rightly.
    it 'keeps it beside a proxy that carries credentials, where the report does not quote them' do
      failure = NameError.new('boom')
      raising = ->(_) { raise failure }

      expect { unit_transport(proxy: 'http://user:s3cret@proxyhost:3128', middleware: raising) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be(failure) }
    end

    it 'keeps the cause of an unregistered adapter' do
      expect { unit_transport(adapter: :nonsense) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be_a(Faraday::Error) }
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

    # `String#to_s` hands back the receiver, so the scoped transport held the
    # caller's own String: a login buffer reused after the scope was taken
    # changed who every later request was performed for.
    context 'when the string it was given changes afterwards' do
      let(:login)  { +'agent@example.com' }
      let(:scoped) { unit_transport.with_on_behalf_of(login) }

      before do
        scoped
        login.replace('admin@example.com')
      end

      it 'goes on sending the scope it was given' do
        stub = stub_request(:get, url).with(headers: { 'From' => 'agent@example.com' }).to_return(json_response([]))
        scoped.get('api/v1/groups', operation: 'test')

        expect(stub).to have_been_requested
      end

      it 'goes on reporting the scope it was given' do
        expect(scoped.on_behalf_of).to eq('agent@example.com')
      end
    end

    it 'holds the scope frozen' do
      expect(unit_transport.with_on_behalf_of(+'agent@example.com').on_behalf_of).to be_frozen
    end

    it 'leaves the string it was given writable' do
      login = +'agent@example.com'
      unit_transport.with_on_behalf_of(login)

      expect(login).not_to be_frozen
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

  # Left to Ruby, inspect printed the Faraday connection, whose proxy options
  # carry the proxy password and whose middleware stack carries the token it
  # was built with.
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

  # `request` documents that every failure leaves it as a ZammadAPI::Error.
  # Faraday::SSLError was handled and its unwrapped counterpart was not, so a
  # certificate mismatch through an adapter that does not wrap - an adapter
  # this gem lets a caller choose - went straight past the rescue.
  describe 'a TLS failure through an adapter that does not wrap it' do
    before { BareTlsAdapter.attempts = [] }

    def bare_tls_transport(**overrides)
      unit_transport(adapter: :bare_tls, retry_interval: 0.01, **overrides)
    end

    it 'maps it to ConnectionError rather than letting it out raw' do
      expect { bare_tls_transport.get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError, /TLS handshake with .* failed/)
    end

    it 'is catchable as the gem error every caller rescues' do
      expect { bare_tls_transport.get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::Error)
    end

    # A rejected certificate is a fact about the instance, not a transient
    # failure: retrying only delays the error by the backoff.
    it 'does not retry it' do
      expect { bare_tls_transport(retries: 2).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError)
      expect(BareTlsAdapter.attempts.size).to eq(1)
    end

    it 'keeps the unwrapped TLS error out of the retry list' do
      expect(described_class::RETRIABLE_EXCEPTIONS).not_to include(*described_class::SSL_ERRORS)
    end
  end

  # The error Faraday or URI raises quotes the value it rejected, and for a
  # proxy that value carries its credentials - into a message that lands in
  # every log and exception report.
  describe 'a connection that cannot be built from a credential-bearing proxy' do
    let(:proxy) { 'http://user:pa ss@proxyhost:3128' }

    it 'reports it as a configuration error' do
      expect { unit_transport(proxy: proxy) }.to raise_error(ZammadAPI::ConfigurationError)
    end

    it 'keeps the proxy password out of the message' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to include('pa ss') }
    end

    it 'still says which value was rejected' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError, %r{http://\[REDACTED\]@proxyhost:3128})
    end

    # The message is not what a log or an error tracker prints. They print
    # the report, and Ruby had attached the error being rescued as the cause:
    # the redacted message went out with the original, password and all,
    # right behind it.
    it 'keeps the proxy password out of the whole report, not just the message' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to include('pa ss') }
    end

    it 'does not carry the error that quotes the password along as its cause' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be_nil }
    end

    it 'still names the class of the error it replaced' do
      expect { unit_transport(proxy: proxy) }.to raise_error(ZammadAPI::ConfigurationError, /URI::InvalidURIError/)
    end

    # The error being replaced may be clean itself and still have the
    # password one level down, and a report prints every level.
    context 'when the error quotes the proxy only further down its own chain' do
      let(:proxy) { 'http://user:s3cret@proxyhost:3128' }

      let(:wrapping) do
        lambda do |_|
          raise URI::InvalidURIError, "bad URI: #{proxy}"
        rescue URI::InvalidURIError
          raise ArgumentError, 'the proxy could not be used'
        end
      end

      it 'has nothing to redact in the message' do
        expect { unit_transport(proxy: proxy, middleware: wrapping) }
          .to raise_error(ZammadAPI::ConfigurationError, /ArgumentError: the proxy could not be used/)
      end

      it 'keeps the password out of the whole report all the same' do
        expect { unit_transport(proxy: proxy, middleware: wrapping) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to include('s3cret') }
      end
    end

    # A # ends the authority early, so the redaction found no credential in
    # what was left of it and the message quoted the password in full.
    context 'when the password carries a character that ends the authority' do
      let(:proxy) { 'http://user:pa#ss-s3cret@proxyhost:3128' }

      it 'keeps the password out of the message' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to match(/pa#ss|s3cret/) }
      end

      it 'still says which value was rejected' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError, %r{http://\[REDACTED\]@proxyhost:3128})
      end

      it 'keeps the password out of the whole report' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to match(/pa#ss|s3cret/) }
      end
    end

    context 'when it is the instance url that carries such a password' do
      it 'keeps the password out of the message' do
        expect { unit_transport(url: 'https://admin:pa#ss-s3cret@zammad.test/') }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to match(/pa#ss|s3cret/) }
      end
    end

    # The error quotes what it rejected through `inspect`, which escapes the
    # backslash - so the text in the message stopped matching the configured
    # value and the substring swap redacted nothing at all.
    context 'when the value carries a backslash, which inspect escapes' do
      let(:proxy) { 'http://user:secret@proxyhost/a\0b' }

      it 'still keeps the password out of the message' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to include('secret') }
      end
    end

    # `\0` in a gsub replacement String expands to the matched text, which is
    # the unredacted value.
    context 'when the value carries a sequence a gsub replacement would expand' do
      let(:proxy) { 'http://user:secret@proxyhost/a\0b' }

      it 'does not put the credential back through the replacement' do
        message = begin
          unit_transport(proxy: proxy)
          nil
        rescue ZammadAPI::ConfigurationError => e
          e.message
        end

        expect(message.scan('user:secret')).to be_empty
      end
    end
  end
end
