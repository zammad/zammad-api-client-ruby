# frozen_string_literal: true

RSpec.describe ZammadAPI::Client do
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/users/1" }

  describe '.new' do
    it 'accepts keyword arguments' do
      expect(described_class.new(url: 'http://zammad.test/', http_token: 'token')).to be_a(described_class)
    end

    it 'surfaces configuration errors' do
      expect { described_class.new(http_token: 'token') }.to raise_error(ArgumentError)
    end

    it 'rejects a missing url' do
      expect { described_class.new(url: nil, http_token: 'token') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing url in config')
    end

    it 'rejects an unsupported scheme' do
      expect { described_class.new(url: 'ftp://example.com', http_token: 'token') }
        .to raise_error(ZammadAPI::ConfigurationError, /needs to start with http/)
    end

    it 'rejects missing credentials' do
      expect { described_class.new(url: 'http://zammad.test/') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
    end

    it 'rejects an unknown option' do
      expect { described_class.new(url: 'http://zammad.test/', http_token: 't', nonsense: 1) }
        .to raise_error(ArgumentError)
    end

    it 'exposes the configuration' do
      expect(unit_client.config).to be_a(ZammadAPI::Config)
    end
  end

  describe '.from_env' do
    it 'reads the url and access token' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'from-env' })

      config = described_class.from_env.config
      expect(config.url).to eq('http://zammad.test/')
      expect(config.http_token).to eq('from-env')
    end

    it 'reads basic auth credentials' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_USER' => 'u', 'ZAMMAD_PASSWORD' => 'p' })

      expect(described_class.from_env.config.authentication_scheme).to eq(:basic)
    end

    it 'reads an OAuth2 token' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_OAUTH2_TOKEN' => 'oauth' })

      expect(described_class.from_env.config.oauth2_token).to eq('oauth')
    end

    it 'prefers ZAMMAD_HTTP_TOKEN over ZAMMAD_TOKEN' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'short', 'ZAMMAD_HTTP_TOKEN' => 'explicit' })

      expect(described_class.from_env.config.http_token).to eq('explicit')
    end

    it 'lets an argument win over the environment' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'from-env' })

      expect(described_class.from_env(http_token: 'passed in').config.http_token).to eq('passed in')
    end

    it 'accepts options that have no environment variable' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 't' })

      expect(described_class.from_env(timeout: 300).config.timeout).to eq(300)
    end

    it 'treats an empty variable as unset' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => '', 'ZAMMAD_USER' => 'u', 'ZAMMAD_PASSWORD' => 'p' })

      expect(described_class.from_env.config.authentication_scheme).to eq(:basic)
    end

    it 'names the variable to set when the url is missing' do
      stub_const('ENV', { 'ZAMMAD_TOKEN' => 't' })

      expect { described_class.from_env }
        .to raise_error(ZammadAPI::ConfigurationError, /set ZAMMAD_URL or pass url:/)
    end

    it 'still validates the credentials' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/' })

      expect { described_class.from_env }.to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
    end
  end

  describe '#me' do
    it 'reads the current user' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/me")
        .with(query: { 'expand' => 'true' })
        .to_return(json_response({ id: 3, email: 'agent@example.com' }))

      expect(unit_client.me.email).to eq('agent@example.com')
    end

    it 'returns a persisted user record' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/me").with(query: hash_including({}))
        .to_return(json_response({ id: 3 }))

      me = unit_client.me
      expect(me).to be_a(ZammadAPI::Resources::User)
      expect(me).to be_persisted
    end

    it 'follows an on_behalf_of scope' do
      stub = stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/me")
        .with(query: hash_including({}), headers: { 'From' => 'agent@example.com' })
        .to_return(json_response({ id: 3 }))

      unit_client.on_behalf_of('agent@example.com').me
      expect(stub).to have_been_requested
    end

    it 'raises AuthenticationError for invalid credentials' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/me").with(query: hash_including({}))
        .to_return(json_response({ error: 'authentication failed' }, status: 401))

      expect { unit_client.me }.to raise_error(ZammadAPI::AuthenticationError)
    end
  end

  describe '#version' do
    it 'reports the version of the Zammad instance' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/version").to_return(json_response({ version: '6.4.0' }))

      expect(unit_client.version).to eq('6.4.0')
    end

    it 'is nil when the instance reports no version' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/version").to_return(json_response({}))

      expect(unit_client.version).to be_nil
    end

    it 'is not the version of this gem' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/version").to_return(json_response({ version: '6.4.0' }))

      expect(unit_client.version).not_to eq(ZammadAPI::VERSION)
    end
  end

  describe 'resource readers' do
    ZammadAPI::Client::RESOURCES.each do |name, resource_class|
      it "exposes ##{name}" do
        expect(unit_client.public_send(name).resource_class).to eq(resource_class)
      end

      it "responds to ##{name}" do
        expect(unit_client).to respond_to(name)
      end
    end

    it 'returns a proxy' do
      expect(unit_client.group).to be_a(ZammadAPI::ResourceProxy)
    end

    it 'lists the supported resource names' do
      expect(unit_client.resource_names).to eq(ZammadAPI::Client::RESOURCES.keys)
    end
  end

  describe '#resource' do
    it 'accepts a symbol' do
      expect(unit_client.resource(:group).resource_class).to eq(ZammadAPI::Resources::Group)
    end

    it 'accepts a string' do
      expect(unit_client.resource('group').resource_class).to eq(ZammadAPI::Resources::Group)
    end

    it 'raises for an unknown resource' do
      expect { unit_client.resource(:unicorn) }
        .to raise_error(ZammadAPI::UnknownResourceError, /Unknown resource unicorn/)
    end

    it 'lists the available resources in the error' do
      expect { unit_client.resource(:unicorn) }.to raise_error(/available resources are: group, organization/)
    end
  end

  describe 'unknown methods' do
    it 'raises UnknownResourceError for an unknown resource name' do
      expect { unit_client.unicorn }.to raise_error(ZammadAPI::UnknownResourceError, /Unknown resource unicorn/)
    end

    it 'does not claim to respond to it' do
      expect(unit_client).not_to respond_to(:unicorn)
    end

    it 'still raises NoMethodError for a bang method' do
      expect { unit_client.save! }.to raise_error(NoMethodError)
    end

    it 'still raises NoMethodError for a predicate' do
      expect { unit_client.valid? }.to raise_error(NoMethodError)
    end

    it 'stays usable in array operations that rely on to_ary' do
      client = unit_client
      expect([client].flatten).to eq([client])
    end

    it 'leaves Ruby core methods alone, so only declared resources are dispatched' do
      expect(unit_client.hash).to be_an(Integer)
    end

    it 'defines resource readers on the client itself, so they win over inherited methods' do
      expect(described_class.instance_method(:user).owner).to eq(described_class)
    end
  end

  describe 'raw requests' do
    subject(:client) { unit_client }

    let(:roles_url) { "#{ClientHelper::BASE_URL}api/v1/roles" }

    describe '#get' do
      it 'reaches an endpoint the gem does not model' do
        stub_request(:get, roles_url).to_return(json_response([{ id: 1, name: 'Admin' }]))

        expect(client.get('api/v1/roles').body).to eq([{ id: 1, name: 'Admin' }])
      end

      it 'returns a Response, so the status and headers stay reachable' do
        stub_request(:get, roles_url).to_return(json_response([], headers: { 'X-Total-Count' => '7' }))

        response = client.get('api/v1/roles')
        expect(response).to be_a(ZammadAPI::Response)
        expect(response.status).to eq(200)
        expect(response.headers['x-total-count']).to eq('7')
      end

      it 'ignores a leading slash, so paths can be pasted from the Zammad docs' do
        stub = stub_request(:get, roles_url).to_return(json_response([]))

        client.get('/api/v1/roles')
        expect(stub).to have_been_requested
      end

      it 'keeps the sub-path of a Zammad served from one' do
        stub = stub_request(:get, 'http://zammad.test/helpdesk/api/v1/roles').to_return(json_response([]))

        unit_client(url: 'http://zammad.test/helpdesk/').get('/api/v1/roles')
        expect(stub).to have_been_requested
      end

      it 'passes query parameters' do
        stub = stub_request(:get, roles_url).with(query: { 'active' => 'true' }).to_return(json_response([]))

        client.get('api/v1/roles', query: { active: true })
        expect(stub).to have_been_requested
      end

      it 'sends the configured authentication' do
        stub = stub_request(:get, roles_url)
          .with(headers: { 'Authorization' => 'Token test-token' })
          .to_return(json_response([]))

        client.get('api/v1/roles')
        expect(stub).to have_been_requested
      end

      it 'carries an on_behalf_of scope' do
        stub = stub_request(:get, roles_url)
          .with(headers: { 'From' => 'agent@example.com' })
          .to_return(json_response([]))

        client.on_behalf_of('agent@example.com').get('api/v1/roles')
        expect(stub).to have_been_requested
      end

      it 'raises the mapped error class' do
        stub_request(:get, roles_url).to_return(json_response({ error: 'nope' }, status: 403))

        expect { client.get('api/v1/roles') }.to raise_error(ZammadAPI::AuthorizationError, /nope/)
      end

      it 'names the request in the error message' do
        stub_request(:get, roles_url).to_return(json_response({}, status: 500))

        expect { client.get('api/v1/roles') }
          .to raise_error(ZammadAPI::ServerError, "Can't GET api/v1/roles: HTTP 500")
      end

      it 'hands back a non-JSON body untouched' do
        stub_request(:get, roles_url).to_return(status: 200, body: 'plain', headers: { 'Content-Type' => 'text/plain' })

        expect(client.get('api/v1/roles').body).to eq('plain')
      end
    end

    describe '#post' do
      it 'sends a JSON body' do
        stub = stub_request(:post, roles_url)
          .with(body: JSON.generate({ name: 'Agent' }), headers: { 'Content-Type' => 'application/json' })
          .to_return(json_response({ id: 2 }))

        expect(client.post('api/v1/roles', body: { name: 'Agent' }).body).to eq({ id: 2 })
        expect(stub).to have_been_requested
      end

      it 'is not retried, so a failed create cannot be duplicated' do
        stub_request(:post, roles_url).to_return(json_response({}, status: 500))

        expect { unit_client(retries: 3).post('api/v1/roles', body: {}) }.to raise_error(ZammadAPI::ServerError)
        expect(a_request(:post, roles_url)).to have_been_made.once
      end

      it 'redacts credentials from the log' do
        stub_request(:post, roles_url).to_return(json_response({}))

        log    = StringIO.new
        logger = Logger.new(log, level: Logger::DEBUG)
        unit_client(logger: logger).post('api/v1/roles', body: { password: 'hunter2' })

        expect(log.string).to include('[REDACTED]')
        expect(log.string).not_to include('hunter2')
      end
    end

    describe '#put' do
      it 'sends a JSON body' do
        stub = stub_request(:put, "#{roles_url}/1").with(body: JSON.generate({ name: 'Agent' })).to_return(json_response({ id: 1 }))

        client.put('api/v1/roles/1', body: { name: 'Agent' })
        expect(stub).to have_been_requested
      end
    end

    describe '#delete' do
      it 'passes query parameters, which is how Zammad takes tag removals' do
        stub = stub_request(:delete, "#{ClientHelper::BASE_URL}api/v1/tags/remove")
          .with(query: { 'object' => 'Ticket', 'o_id' => '1', 'item' => 'urgent' })
          .to_return(json_response({ success: true }))

        client.delete('api/v1/tags/remove', query: { object: 'Ticket', o_id: 1, item: 'urgent' })
        expect(stub).to have_been_requested
      end
    end

    it 'does not shadow a resource reader' do
      expect(client.resource_names).not_to include(:get, :post, :put, :delete)
    end
  end

  describe '#on_behalf_of' do
    before do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response({ id: 1 }))
    end

    it 'sends the From header' do
      stub = stub_request(:get, url)
        .with(query: hash_including({}), headers: { 'From' => 'agent@example.com' })
        .to_return(json_response({ id: 1 }))

      unit_client.on_behalf_of('agent@example.com').user.find(1)
      expect(stub).to have_been_requested
    end

    it 'returns a new client' do
      client = unit_client
      expect(client.on_behalf_of('someone')).not_to be(client)
    end

    it 'leaves the original client unscoped' do
      client = unit_client
      client.on_behalf_of('someone')
      client.user.find(1)

      expect(a_request(:get, url).with { |request| request.headers.key?('From') }).not_to have_been_made
    end

    it 'keeps the scoped client usable for several requests' do
      scoped = unit_client.on_behalf_of('agent@example.com')
      scoped.user.find(1)
      scoped.user.find(1)

      expect(a_request(:get, url).with(query: hash_including({}), headers: { 'From' => 'agent@example.com' }))
        .to have_been_made.twice
    end

    describe 'block form' do
      it 'yields a scoped client' do
        unit_client.on_behalf_of('agent@example.com') { |scoped| scoped.user.find(1) }

        expect(a_request(:get, url).with(query: hash_including({}), headers: { 'From' => 'agent@example.com' }))
          .to have_been_made
      end

      it 'returns the block value' do
        expect(unit_client.on_behalf_of('agent@example.com') { :done }).to eq(:done)
      end

      it 'does not affect the outer client when the block raises' do
        client = unit_client

        expect { client.on_behalf_of('agent@example.com') { raise 'boom' } }.to raise_error('boom')

        client.user.find(1)
        expect(a_request(:get, url).with { |request| request.headers.key?('From') }).not_to have_been_made
      end
    end
  end

  describe '#with' do
    it 'returns a new client' do
      client = unit_client
      expect(client.with(timeout: 5)).not_to be(client)
    end

    it 'applies the changed option' do
      expect(unit_client.with(timeout: 5).config.timeout).to eq(5)
    end

    it 'leaves the original client untouched' do
      client = unit_client
      client.with(timeout: 5)
      expect(client.config.timeout).to eq(ZammadAPI::Config::DEFAULT_TIMEOUT)
    end

    it 'keeps the options that were not changed' do
      expect(unit_client.with(timeout: 5).config.http_token).to eq('test-token')
    end

    it 're-validates the resulting configuration' do
      expect { unit_client.with(timeout: -1) }
        .to raise_error(ZammadAPI::ConfigurationError, /positive number/)
    end

    it 'carries an on_behalf_of scope over to the derived client' do
      stub = stub_request(:get, url)
        .with(query: hash_including({}), headers: { 'From' => 'agent@example.com' })
        .to_return(json_response({ id: 1 }))

      unit_client.on_behalf_of('agent@example.com').with(timeout: 5).user.find(1)
      expect(stub).to have_been_requested
    end

    it 'still works for requests' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response({ id: 1 }))
      expect(unit_client.with(timeout: 5).user.find(1).id).to eq(1)
    end
  end

  describe 'concurrent use' do
    it 'does not leak an on_behalf_of scope between threads' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response({ id: 1 }))

      client = unit_client
      logins = %w[a@example.com b@example.com c@example.com]

      threads = logins.map do |login|
        Thread.new { 5.times { client.on_behalf_of(login).user.find(1) } }
      end
      threads << Thread.new { 5.times { client.user.find(1) } }
      threads.each(&:join)

      logins.each do |login|
        expect(a_request(:get, url).with(query: hash_including({}), headers: { 'From' => login }))
          .to have_been_made.times(5)
      end
    end

    it 'leaves the shared client unscoped throughout' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response({ id: 1 }))

      client = unit_client
      threads = %w[a@example.com b@example.com].map do |login|
        Thread.new { 5.times { client.on_behalf_of(login).user.find(1) } }
      end
      threads.each(&:join)

      client.user.find(1)

      expect(
        a_request(:get, url).with(query: hash_including({})) { |request| !request.headers.key?('From') }
      ).to have_been_made
    end
  end

  describe '#inspect' do
    it 'shows the url and auth scheme' do
      expect(unit_client.inspect)
        .to eq('#<ZammadAPI::Client url="http://zammad.test/" auth=http_token>')
    end

    it 'does not leak the token' do
      expect(unit_client(http_token: 'super-secret').inspect).not_to include('super-secret')
    end
  end
end
