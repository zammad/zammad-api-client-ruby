# frozen_string_literal: true

RSpec.describe ZammadAPI::Client do
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/users/1" }

  describe '.new' do
    it 'refuses more than one way to authenticate' do
      expect { described_class.new(url: 'http://zammad.test/', http_token: 't', user: 'u', password: 'p') }
        .to raise_error(ZammadAPI::ConfigurationError, /more than one way to authenticate/)
    end

    it 'accepts keyword arguments' do
      expect(described_class.new(url: 'http://zammad.test/', http_token: 'token')).to be_a(described_class)
    end

    it 'surfaces configuration errors' do
      expect { described_class.new(http_token: 'token') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing url in config')
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

    it 'lets an argument win over the environment' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'from-env' })

      expect(described_class.from_env(http_token: 'passed in').config.http_token).to eq('passed in')
    end

    context 'with a variable that is empty or only whitespace' do
      let(:environment) { { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'from-env' } }

      def from(variables)
        stub_const('ENV', environment.merge(variables))
        described_class.from_env
      end

      %w[ZAMMAD_USER ZAMMAD_PASSWORD ZAMMAD_OAUTH2_TOKEN].each do |name|
        it "does not take a #{name} of a space for a second way to authenticate" do
          expect(from(name => ' ').config.authentication_scheme).to eq(:http_token)
        end
      end

      it 'says that the url is missing for a ZAMMAD_URL of a space' do
        expect { from('ZAMMAD_URL' => ' ') }.to raise_error(ZammadAPI::ConfigurationError, /\Amissing url: set ZAMMAD_URL/)
      end

      it 'says what is missing where no variable holds a credential' do
        stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => ' ', 'ZAMMAD_USER' => "\t" })

        expect { described_class.from_env }.to raise_error(ZammadAPI::ConfigurationError, /missing user in config/)
      end

      it 'strips the whitespace around a token that holds more than that' do
        expect(from('ZAMMAD_TOKEN' => " padded\n").config.http_token).to eq('padded')
      end

      it 'still takes a password of spaces that is passed in' do
        stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_USER' => 'u', 'ZAMMAD_PASSWORD' => '  ' })

        expect(described_class.from_env(password: '  ').config.password).to eq('  ')
      end
    end

    context 'when an argument names another way to authenticate' do
      before do
        stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 'from-env' })
      end

      it 'uses a user and password passed in, not the token in the environment' do
        expect(described_class.from_env(user: 'u', password: 'p').config.authentication_scheme).to eq(:basic)
      end

      it 'drops the token the environment held' do
        expect(described_class.from_env(user: 'u', password: 'p').config.http_token).to be_nil
      end

      it 'uses an OAuth2 token passed in, not the token in the environment' do
        expect(described_class.from_env(oauth2_token: 'x').config.authentication_scheme).to eq(:oauth2_token)
      end

      it 'sends what was passed in' do
        stub = stub_request(:get, 'http://zammad.test/api/v1/users/1')
          .with(query: hash_including({}), basic_auth: %w[u p])
          .to_return(json_response({ id: 1 }))

        described_class.from_env(user: 'u', password: 'p', retries: 0).users.find(1)
        expect(stub).to have_been_requested
      end
    end

    it 'refuses an environment that sets more than one way to authenticate' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 't', 'ZAMMAD_USER' => 'u', 'ZAMMAD_PASSWORD' => 'p' })

      expect { described_class.from_env }
        .to raise_error(ZammadAPI::ConfigurationError, /more than one way to authenticate \(http_token, user and password\)/)
    end

    it 'lets an argument say which of them is meant' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_TOKEN' => 't', 'ZAMMAD_USER' => 'u', 'ZAMMAD_PASSWORD' => 'p' })

      expect(described_class.from_env(http_token: 't').config.authentication_scheme).to eq(:http_token)
    end

    it 'keeps the user from the environment when only the password is passed in' do
      stub_const('ENV', { 'ZAMMAD_URL' => 'http://zammad.test/', 'ZAMMAD_USER' => 'u', 'ZAMMAD_PASSWORD' => 'old' })

      config = described_class.from_env(password: 'new').config
      expect([config.user, config.password]).to eq(%w[u new])
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
      expect(unit_client.groups).to be_a(ZammadAPI::ResourceProxy)
    end

    it 'lists the supported resource names' do
      expect(unit_client.resource_names).to eq(ZammadAPI::Client::RESOURCES.keys)
    end
  end

  describe 'the singular names the readers had in 1.x' do
    %i[group organization ticket ticket_article ticket_priority ticket_state user].each do |old_name|
      it "does not answer ##{old_name}" do
        expect { unit_client.public_send(old_name) }
          .to raise_error(ZammadAPI::UnknownResourceError, /Unknown resource #{old_name}, available resources are: groups, /)
      end
    end

    it 'does not claim to respond to one' do
      expect(unit_client).not_to respond_to(:ticket)
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

    it 'lists the available resources in the error' do
      expect { unit_client.resource(:unicorn) }.to raise_error(/available resources are: groups, organizations/)
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

      it 'finds one by id' do
        stub_request(:get, "#{roles_url}/2").with(query: hash_including({})).to_return(json_response({ id: 2, name: 'Agent' }))

        expect(client.resource(Role).find(2).name).to eq('Agent')
      end

      it 'saves a change to one, sending only what changed' do
        stub_request(:get, "#{roles_url}/2").with(query: hash_including({})).to_return(json_response({ id: 2, name: 'Agent', note: nil }))
        update = stub_request(:put, "#{roles_url}/2").with(query: hash_including({}), body: { note: 'Reviewed' })
          .to_return(json_response({ id: 2, name: 'Agent', note: 'Reviewed' }))

        client.resource(Role).find(2).update(note: 'Reviewed')
        expect(update).to have_been_requested
      end

      it 'creates one' do
        create = stub_request(:post, roles_url).with(query: hash_including({}), body: { name: 'Auditor' })
          .to_return(json_response({ id: 9, name: 'Auditor' }, status: 201))

        expect(client.resource(Role).create(name: 'Auditor').id).to eq(9)
        expect(create).to have_been_requested
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

      it 'takes a subclass of a class this gem models' do
        stub_const('MyTicket', Class.new(ZammadAPI::Resources::Ticket))
        stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/tickets/1").with(query: hash_including({})).to_return(json_response({ id: 1 }))

        expect(client.resource(MyTicket).find(1)).to be_a(MyTicket)
      end

      it 'leaves the client as it was built' do
        expect { client.resource(Role) }.not_to(change { client.instance_variable_get(:@resources).size })
      end
    end

    it 'raises for a singular name from 1.x' do
      expect { unit_client.resource(:ticket) }
        .to raise_error(ZammadAPI::UnknownResourceError, /Unknown resource ticket, available resources are: groups, /)
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
      expect(described_class.instance_method(:users).owner).to eq(described_class)
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

      it 'refuses an absolute URL rather than sending the credentials to another host' do
        expect { client.get('https://other.example/collect') }
          .to raise_error(ArgumentError, /a request path is relative to the instance URL/)
      end

      it 'makes no request for an absolute URL' do
        stub_request(:any, /other\.example/)

        expect { client.get('https://other.example/collect') }.to raise_error(ArgumentError)
        expect(a_request(:any, /other\.example/)).not_to have_been_made
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

      it 'takes a URL written into the query string' do
        stub = stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/roles").with(query: { 'next' => 'http://other.example/x' }).to_return(json_response({}))
        client.get('api/v1/roles?next=http://other.example/x')
        expect(stub).to have_been_requested
      end

      it 'refuses an absolute URL for every verb' do
        %i[post put delete].each do |verb|
          expect { client.public_send(verb, 'https://other.example/collect') }.to raise_error(ArgumentError, /absolute URL/)
        end
      end

      it 'does not quote the path it refuses, which may carry a secret' do
        expect { client.get('https://other.example/collect?token=s3cret') }
          .to raise_error(ArgumentError) { |error| expect(error.message).not_to include('s3cret') }
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

      it 'sends the headers it was given' do
        stub = stub_request(:get, roles_url)
          .with(headers: { 'Accept-Language' => 'de-de' })
          .to_return(json_response([]))

        client.get('api/v1/roles', headers: { 'Accept-Language' => 'de-de' })
        expect(stub).to have_been_requested
      end

      it 'sends a header value that is not a String as text' do
        stub = stub_request(:get, roles_url)
          .with(headers: { 'X-Retry' => '3' })
          .to_return(json_response([]))

        client.get('api/v1/roles', headers: { 'X-Retry' => 3 })
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

      it 'redacts a credential-bearing header from the log too' do
        stub_request(:post, roles_url).to_return(json_response({}))

        log    = StringIO.new
        logger = Logger.new(log, level: Logger::DEBUG)
        unit_client(logger: logger).post('api/v1/roles', headers: { 'X-Api-Key' => 'hunter2' })

        expect(log.string).to include('[REDACTED]')
        expect(log.string).not_to include('hunter2')
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

    it 'keeps the on_behalf_of scope alongside a caller header' do
      stub = stub_request(:get, roles_url)
        .with(headers: { 'From' => 'agent@example.com', 'X-Trace' => 'abc' })
        .to_return(json_response([]))

      client.on_behalf_of('agent@example.com').get('api/v1/roles', headers: { 'X-Trace' => 'abc' })
      expect(stub).to have_been_requested
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

      unit_client.on_behalf_of('agent@example.com').users.find(1)
      expect(stub).to have_been_requested
    end

    it 'returns a new client' do
      client = unit_client
      expect(client.on_behalf_of('someone')).not_to be(client)
    end

    it 'leaves the original client unscoped' do
      client = unit_client
      client.on_behalf_of('someone')
      client.users.find(1)

      expect(a_request(:get, url).with { |request| request.headers.key?('From') }).not_to have_been_made
    end

    it 'keeps the scoped client usable for several requests' do
      scoped = unit_client.on_behalf_of('agent@example.com')
      scoped.users.find(1)
      scoped.users.find(1)

      expect(a_request(:get, url).with(query: hash_including({}), headers: { 'From' => 'agent@example.com' }))
        .to have_been_made.twice
    end

    it 'takes a user id' do
      stub = stub_request(:get, url).with(query: hash_including({}), headers: { 'From' => '7' }).to_return(json_response({ id: 1 }))
      unit_client.on_behalf_of(7).users.find(1)

      expect(stub).to have_been_requested
    end

    it 'strips whitespace around the identifier' do
      stub = stub_request(:get, url).with(query: hash_including({}), headers: { 'From' => 'agent@example.com' }).to_return(json_response({ id: 1 }))
      unit_client.on_behalf_of(" agent@example.com\n").users.find(1)

      expect(stub).to have_been_requested
    end

    describe 'an identifier that names nobody' do
      [nil, '', '   ', "\t\n"].each do |blank|
        it "refuses #{blank.inspect}" do
          expect { unit_client.on_behalf_of(blank) }
            .to raise_error(ArgumentError, "on_behalf_of needs the login, email address or id of a user, got #{blank.inspect}")
        end
      end

      it 'refuses it before the block is run' do
        ran = false
        expect { unit_client.on_behalf_of('') { ran = true } }.to raise_error(ArgumentError)

        expect(ran).to be(false)
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

      it 'does not affect the outer client when the block raises' do
        client = unit_client

        expect { client.on_behalf_of('agent@example.com') { raise 'boom' } }.to raise_error('boom')

        client.users.find(1)
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
      expect { unit_client.with(url: 'zammad.example.com') }
        .to raise_error(ZammadAPI::ConfigurationError, /needs to start with http/)
    end

    context 'when it names another way to authenticate' do
      it 'switches to an OAuth2 token' do
        expect(unit_client.with(oauth2_token: 'x').config.authentication_scheme).to eq(:oauth2_token)
      end

      it 'switches to a user and password' do
        expect(unit_client.with(user: 'u', password: 'p').config.authentication_scheme).to eq(:basic)
      end

      it 'drops the credential it replaced' do
        expect(unit_client.with(oauth2_token: 'x').config.http_token).to be_nil
      end

      it 'sends the new credential' do
        stub = stub_request(:get, url)
          .with(query: hash_including({}), headers: { 'Authorization' => 'Bearer x' })
          .to_return(json_response({ id: 1 }))

        unit_client.with(oauth2_token: 'x').users.find(1)
        expect(stub).to have_been_requested
      end

      it 'leaves the original client on its own credential' do
        client = unit_client
        client.with(oauth2_token: 'x')
        expect(client.config.authentication_scheme).to eq(:http_token)
      end

      it 'switches back to an access token from basic authentication' do
        basic = unit_client(http_token: nil, user: 'u', password: 'p')
        expect(basic.with(http_token: 't').config.to_h.slice(:user, :password, :http_token))
          .to eq({ user: nil, password: nil, http_token: 't' })
      end
    end

    it 'replaces a token of the same kind' do
      expect(unit_client.with(http_token: 'other').config.http_token).to eq('other')
    end

    it 'keeps the user when only the password changes' do
      basic = unit_client(http_token: nil, user: 'u', password: 'old').with(password: 'new')
      expect([basic.config.user, basic.config.password]).to eq(%w[u new])
    end

    it 'carries an on_behalf_of scope over to the derived client' do
      stub = stub_request(:get, url)
        .with(query: hash_including({}), headers: { 'From' => 'agent@example.com' })
        .to_return(json_response({ id: 1 }))

      unit_client.on_behalf_of('agent@example.com').with(timeout: 5).users.find(1)
      expect(stub).to have_been_requested
    end

    it 'still works for requests' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response({ id: 1 }))
      expect(unit_client.with(timeout: 5).users.find(1).id).to eq(1)
    end
  end

  describe 'concurrent use' do
    it 'does not leak an on_behalf_of scope between threads' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response({ id: 1 }))

      client = unit_client
      logins = %w[a@example.com b@example.com c@example.com]

      threads = logins.map do |login|
        Thread.new { 5.times { client.on_behalf_of(login).users.find(1) } }
      end
      threads << Thread.new { 5.times { client.users.find(1) } }
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
        Thread.new { 5.times { client.on_behalf_of(login).users.find(1) } }
      end
      threads.each(&:join)

      client.users.find(1)

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

    it 'is not mutated by reading a proxy off it' do
      before_read = client.instance_variable_get(:@resources)
      client.tickets

      expect(client.instance_variable_get(:@resources)).to be(before_read)
    end

    it 'holds a proxy for every resource before any is asked for' do
      expect(client.instance_variable_get(:@resources).size).to eq(client.resource_names.size)
    end

    it 'refuses to be written to after it is built' do
      expect(client.instance_variable_get(:@resources)).to be_frozen
    end

    it 'hands out a different proxy per resource' do
      expect(client.tickets).not_to be(client.users)
    end

    it 'does not carry a proxy over to an on_behalf_of client' do
      expect(client.on_behalf_of('agent@example.com').tickets).not_to be(client.tickets)
    end

    it 'does not carry a proxy over to a client built with #with' do
      expect(client.with(timeout: 5).tickets).not_to be(client.tickets)
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
