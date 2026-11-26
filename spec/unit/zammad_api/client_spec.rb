# frozen_string_literal: true

RSpec.describe ZammadAPI::Client do
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/users/1" }

  describe '.new' do
    it 'accepts keyword arguments' do
      expect(described_class.new(url: 'http://zammad.test/', http_token: 'token')).to be_a(described_class)
    end

    it 'surfaces configuration errors' do
      expect { described_class.new(http_token: 'token') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing url in config')
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

    it 'lets an argument win over the environment' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'from-env' })

      expect(described_class.from_env(http_token: 'passed in').config.http_token).to eq('passed in')
    end

    context 'when an argument names another way to authenticate' do
      before do
        stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'from-env' })
      end

      it 'uses a user and password passed in, not the token in the environment' do
        expect(described_class.from_env(user: 'u', password: 'p').config.authentication_scheme).to eq(:basic)
      end
    end

    it 'accepts options that have no environment variable' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 't' })

      expect(described_class.from_env(timeout: 300).config.timeout).to eq(300)
    end

    it 'treats a blank variable as unset' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 't', 'ZAMMAD_USER' => ' ' })

      expect(described_class.from_env.config.authentication_scheme).to eq(:http_token)
    end

    it 'names the variable to set when the url is missing' do
      stub_const('ENV', { 'ZAMMAD_TOKEN' => 't' })

      expect { described_class.from_env }
        .to raise_error(ZammadAPI::ConfigurationError, /set ZAMMAD_URL or pass url:/)
    end
  end

  describe '#me' do
    it 'reads the current user' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/me")
        .with(query: { 'expand' => 'true' })
        .to_return(json_response({ id: 3, email: 'agent@example.com' }))

      expect(unit_client.me.email).to eq('agent@example.com')
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
  end

  describe 'resource readers' do
    ZammadAPI::Client::RESOURCES.each do |name, resource_class|
      it "exposes ##{name}" do
        expect(unit_client.public_send(name).resource_class).to eq(resource_class)
      end
    end

    it 'lists the supported resource names' do
      expect(unit_client.resource_names).to eq(ZammadAPI::Client::RESOURCES.keys)
    end
  end

  describe 'the singular names the readers had in 1.x' do
    [:ticket].each do |old_name|
      it "does not answer ##{old_name}" do
        expect { unit_client.public_send(old_name) }
          .to raise_error(ZammadAPI::UnknownResourceError, /Unknown resource #{old_name}, available resources are: groups, /)
      end
    end
  end

  describe '#resource' do
    it 'accepts a symbol' do
      expect(unit_client.resource(:groups).resource_class).to eq(ZammadAPI::Resources::Group)
    end

    it 'accepts a string' do
      expect(unit_client.resource('groups').resource_class).to eq(ZammadAPI::Resources::Group)
    end

    it 'answers with the proxy the reader answers with' do
      client = unit_client
      expect(client.resource(:ticket_priorities)).to be(client.ticket_priorities)
    end

    it 'raises for an unknown resource' do
      expect { unit_client.resource(:unicorn) }
        .to raise_error(ZammadAPI::UnknownResourceError, /Unknown resource unicorn/)
    end

    context 'with a resource class a caller declared' do
      let(:client)    { unit_client }
      let(:roles_url) { "#{ClientHelper::BASE_URL}api/v1/roles" }

      before do
        stub_const('Role', Class.new(ZammadAPI::Resources::Base) { path 'api/v1/roles' })
      end

      it 'answers with a proxy for that class' do
        expect(client.resource(Role).resource_class).to be(Role)
      end

      it 'reads records of that class from the path it declares' do
        stub_request(:get, roles_url).with(query: hash_including({}))
          .to_return(json_response([{ id: 1, name: 'Admin' }]), json_response([]))

        expect(client.resource(Role).map { [it.class, it.name] }).to eq([[Role, 'Admin']])
      end

      it 'sends the scope of the client it was asked of' do
        stub = stub_request(:get, "#{roles_url}/2")
          .with(query: hash_including({}), headers: { 'From' => 'agent@example.com' })
          .to_return(json_response({ id: 2 }))

        client.on_behalf_of('agent@example.com').resource(Role).find(2)
        expect(stub).to have_been_requested
      end

      it 'answers a class this gem models with the proxy its reader answers with' do
        expect(client.resource(ZammadAPI::Resources::Ticket)).to be(client.tickets)
      end
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

      it 'refuses an absolute URL whatever the case of its scheme' do
        expect { client.get('HTTP://other.example/collect') }.to raise_error(ArgumentError, /absolute URL/)
      end

      it 'refuses an absolute URL behind a leading slash' do
        expect { client.get('/https://other.example/collect') }.to raise_error(ArgumentError, /absolute URL/)
      end

      it 'refuses a path that opens with a scheme and no host' do
        expect { client.get('http:/collect') }.to raise_error(ArgumentError, /absolute URL/)
      end

      it 'takes a colon after the first segment, which leaves the path relative' do
        stub = stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/tags:x").to_return(json_response({}))
        client.get('api/v1/tags:x')
        expect(stub).to have_been_requested
      end

      it 'sends a query string written into the path' do
        stub = stub_request(:get, roles_url).with(query: { 'name' => 'prüfung', 'page' => '2' }).to_return(json_response([]))

        client.get('api/v1/roles?name=pr%C3%BCfung&page=2')
        expect(stub).to have_been_requested
      end

      it 'keeps a protocol-relative path on the instance' do
        stub = stub_request(:get, 'http://zammad.test/other.example/collect').to_return(json_response([]))

        client.get('//other.example/collect')
        expect(stub).to have_been_requested
      end

      it 'passes query parameters' do
        stub = stub_request(:get, roles_url).with(query: { 'active' => 'true' }).to_return(json_response([]))

        client.get('api/v1/roles', query: { active: true })
        expect(stub).to have_been_requested
      end

      it 'carries an on_behalf_of scope' do
        stub = stub_request(:get, roles_url)
          .with(headers: { 'From' => 'agent@example.com' })
          .to_return(json_response([]))

        client.on_behalf_of('agent@example.com').get('api/v1/roles')
        expect(stub).to have_been_requested
      end

      it 'sends the headers it was given' do
        stub = stub_request(:get, roles_url)
          .with(headers: { 'Accept-Language' => 'de-de' })
          .to_return(json_response([]))

        client.get('api/v1/roles', headers: { 'Accept-Language' => 'de-de' })
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

      it 'leaves a query string written into the path out of the error message' do
        stub_request(:get, roles_url).with(query: hash_including({})).to_return(json_response({}, status: 500))

        expect { client.get('api/v1/roles?token=path-s3cret&page=2') }
          .to raise_error(ZammadAPI::ServerError, "Can't GET api/v1/roles: HTTP 500")
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

      it 'sends the headers it was given' do
        stub = stub_request(:post, roles_url).with(headers: { 'X-Trace' => 'abc' }).to_return(json_response({}))

        client.post('api/v1/roles', body: {}, headers: { 'X-Trace' => 'abc' })
        expect(stub).to have_been_requested
      end
    end

    describe '#put' do
      it 'sends a JSON body' do
        stub = stub_request(:put, "#{roles_url}/1").with(body: JSON.generate({ name: 'Agent' })).to_return(json_response({ id: 1 }))

        client.put('api/v1/roles/1', body: { name: 'Agent' })
        expect(stub).to have_been_requested
      end

      it 'sends the headers it was given' do
        stub = stub_request(:put, "#{roles_url}/1").with(headers: { 'X-Trace' => 'abc' }).to_return(json_response({}))

        client.put('api/v1/roles/1', body: {}, headers: { 'X-Trace' => 'abc' })
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

      it 'sends the headers it was given' do
        stub = stub_request(:delete, roles_url).with(headers: { 'X-Trace' => 'abc' }).to_return(json_response({}))

        client.delete('api/v1/roles', headers: { 'X-Trace' => 'abc' })
        expect(stub).to have_been_requested
      end
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

      unit_client.on_behalf_of('agent@example.com').users.find(1)
      expect(stub).to have_been_requested
    end

    it 'leaves the original client unscoped' do
      client = unit_client
      client.on_behalf_of('someone')
      client.users.find(1)

      expect(a_request(:get, url).with { |request| request.headers.key?('From') }).not_to have_been_made
    end

    describe 'an identifier that names nobody' do
      [nil].each do |blank|
        it "refuses #{blank.inspect}" do
          expect { unit_client.on_behalf_of(blank) }
            .to raise_error(ArgumentError, "on_behalf_of needs the login, email address or id of a user, got #{blank.inspect}")
        end
      end
    end

    describe 'block form' do
      it 'yields a scoped client' do
        unit_client.on_behalf_of('agent@example.com') { |scoped| scoped.users.find(1) }

        expect(a_request(:get, url).with(query: hash_including({}), headers: { 'From' => 'agent@example.com' }))
          .to have_been_made
      end

      it 'returns the block value' do
        expect(unit_client.on_behalf_of('agent@example.com') { :done }).to eq(:done)
      end
    end
  end

  describe '#with' do
    it 'applies the changed option' do
      expect(unit_client.with(timeout: 5).config.timeout).to eq(5)
    end

    it 'leaves the original client untouched' do
      client = unit_client
      client.with(timeout: 5)
      expect(client.config.timeout).to eq(ZammadAPI::Config::DEFAULT_TIMEOUT)
    end

    context 'when it names another way to authenticate' do
      it 'sends the new credential' do
        stub = stub_request(:get, url)
          .with(query: hash_including({}), headers: { 'Authorization' => 'Bearer x' })
          .to_return(json_response({ id: 1 }))

        unit_client.with(oauth2_token: 'x').users.find(1)
        expect(stub).to have_been_requested
      end
    end

    it 'carries an on_behalf_of scope over to the derived client' do
      stub = stub_request(:get, url)
        .with(query: hash_including({}), headers: { 'From' => 'agent@example.com' })
        .to_return(json_response({ id: 1 }))

      unit_client.on_behalf_of('agent@example.com').with(timeout: 5).users.find(1)
      expect(stub).to have_been_requested
    end
  end

  describe '#inspect' do
    it 'shows the url and auth scheme' do
      expect(unit_client.inspect)
        .to eq('#<ZammadAPI::Client url="http://zammad.test/" auth=http_token>')
    end

    it 'shows the user a scoped client acts for' do
      expect(unit_client.on_behalf_of('agent@example.com').inspect)
        .to eq('#<ZammadAPI::Client url="http://zammad.test/" auth=http_token on_behalf_of="agent@example.com">')
    end
  end

  describe 'resource proxies' do
    subject(:client) { unit_client }

    it 'hands out the same proxy for the same resource' do
      first = client.tickets

      expect(client.tickets).to be(first)
    end

    it 'refuses to be written to after it is built' do
      expect(client.instance_variable_get(:@resources)).to be_frozen
    end

    it 'gives a derived client a proxy that carries its own scope' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/tickets/1")
        .with(query: hash_including({})).to_return(json_response({ id: 1 }))

      client.tickets
      client.on_behalf_of('agent@example.com').tickets.find(1)

      expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/tickets/1")
        .with(query: hash_including({}), headers: { 'From' => 'agent@example.com' })).to have_been_made
    end
  end
end
