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
