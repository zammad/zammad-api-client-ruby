# frozen_string_literal: true

require 'zammad_api/test'

RSpec.describe ZammadAPI::Test do
  subject(:zammad) { described_class.new }

  let(:client) { zammad.client }

  describe '#client' do
    it 'is a real client' do
      expect(client).to be_a(ZammadAPI::Client)
    end

    it 'opens no connection at all' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
      client.group.find(1)

      expect(a_request(:any, //)).not_to have_been_made
    end

    it 'reports the stand-in configuration' do
      expect(client.config.url).to eq('https://zammad.test/')
    end

    it 'accepts configuration overrides' do
      expect(described_class.new(url: 'https://other.test/').client.config.url).to eq('https://other.test/')
    end

    it 'is the same client every time, rather than a new HTTP stack per call' do
      expect(zammad.client).to equal(zammad.client)
    end
  end

  describe '#stub' do
    it 'answers a find with a record' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })

      expect(client.group.find(1).name).to eq('Users')
    end

    it 'builds records that behave like fetched ones' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })

      group = client.group.find(1)
      expect(group).to be_persisted
      expect { group.attributes[:name] = 'x' }.to raise_error(FrozenError)
    end

    it 'answers a collection with every page' do
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(client.group.pluck(:name)).to eq(%w[Users Support])
    end

    it 'ignores a leading slash on the stub' do
      zammad.stub(:get, '/api/v1/groups/1', body: { id: 1 })

      expect(client.group.find(1).id).to eq(1)
    end

    it 'raises the mapped error class for a non-2xx status' do
      zammad.stub(:get, 'api/v1/groups/1', status: 404, body: { error: 'not found' })

      expect { client.group.find(1) }.to raise_error(ZammadAPI::NotFoundError, /not found/)
    end

    it 'raises a validation error that save reports as false' do
      zammad.stub(:post, 'api/v1/groups', status: 422, body: { error: 'Name is required' })

      group = client.group.new(name: '')
      expect(group.save).to be(false)
      expect(group.error.server_message).to eq('Name is required')
    end

    it 'serves a non-JSON body untouched, e.g. an attachment' do
      zammad.stub(:get, 'api/v1/ticket_attachment/1/2/3', body: 'binary-ish')

      attachment = ZammadAPI::Resources::TicketArticleAttachment
        .new(zammad.client.ticket.new.transport, id: 3, ticket_id: 1, article_id: 2)

      expect(attachment.download).to eq('binary-ish')
    end

    it 'returns itself, so stubs can be chained' do
      expect(zammad.stub(:get, 'api/v1/groups', body: [])).to be(zammad)
    end

    it 'accepts string keys in the body' do
      zammad.stub(:get, 'api/v1/groups/1', body: { 'id' => 1, 'name' => 'Users' })

      expect(client.group.find(1).name).to eq('Users')
    end

    it 'exposes response headers' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => '7' })

      expect(client.get('api/v1/groups').headers['x-total-count']).to eq('7')
    end

    describe 'a sequence' do
      it 'serves stubs in the order they were declared' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'First' })
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Second' })

        expect(client.group.find(1).name).to eq('First')
        expect(client.group.find(1).name).to eq('Second')
      end

      it 'keeps answering with the last one' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'First' })
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Second' })

        3.times { client.group.find(1) }
        expect(client.group.find(1).name).to eq('Second')
      end

      it 'reuses a single stub for any number of requests' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })

        expect(Array.new(3) { client.group.find(1).name }).to eq(%w[Users Users Users])
      end
    end

    describe 'query matching' do
      it 'matches a stub that names a subset of the parameters' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { active: true })

        expect(client.group.where(active: true).first.id).to eq(1)
      end

      it 'does not answer a request without those parameters' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { active: true })

        expect { client.group.all.to_a }.to raise_error(described_class::UnstubbedRequestError)
      end

      it 'ignores the parameters the client adds itself' do
        zammad.stub(:get, 'api/v1/groups', body: [], query: { active: true })

        expect { client.group.where(active: true).to_a }.not_to raise_error
      end
    end
  end

  describe 'an unstubbed request' do
    it 'raises rather than returning something empty' do
      expect { client.group.find(1) }.to raise_error(described_class::UnstubbedRequestError)
    end

    it 'names the request that was not stubbed' do
      expect { client.group.find(1) }
        .to raise_error(%r{GET api/v1/groups/1 was not stubbed})
    end

    it 'says so when nothing at all is stubbed' do
      expect { client.group.find(1) }.to raise_error(/nothing is stubbed/)
    end

    it 'lists what is stubbed, because a wrong path is the usual cause' do
      zammad.stub(:get, 'api/v1/groups/2', body: { id: 2 })

      expect { client.group.find(1) }.to raise_error(%r{stubbed: GET api/v1/groups/2})
    end

    it 'is a ZammadAPI::Error, so a suite can rescue it with the rest' do
      expect(described_class::UnstubbedRequestError.ancestors).to include(ZammadAPI::Error)
    end
  end

  describe '#requests' do
    before do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })
      zammad.stub(:put, 'api/v1/groups/1', body: { id: 1, name: 'Renamed' })
    end

    it 'records the verb and path' do
      client.group.find(1)

      expect(zammad.requests.last.verb).to eq(:get)
      expect(zammad.requests.last.path).to eq('api/v1/groups/1')
    end

    it 'records only what a save actually sends' do
      client.group.find(1).update!(name: 'Renamed')

      expect(zammad.requests.last.body).to eq({ name: 'Renamed' })
    end

    it 'records the query parameters the client sent' do
      client.group.find(1)

      expect(zammad.requests.last.query).to eq({ 'expand' => 'true' })
    end

    it 'records them stringified, the way the transport sends them' do
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }])
      client.group.all.page(2, of: 50).to_a

      expect(zammad.requests.last.query)
        .to eq({ 'expand' => 'true', 'page' => '2', 'per_page' => '50' })
    end

    it 'rejects a nil query value the way the transport does' do
      expect { client.group.where(note: nil).to_a }
        .to raise_error(ArgumentError, /query parameter note is nil/)
    end

    it 'records requests oldest first' do
      client.group.find(1).update!(name: 'Renamed')

      expect(zammad.requests.map(&:verb)).to eq(%i[get put])
    end

    it 'records an on_behalf_of scope' do
      client.on_behalf_of('agent@example.com').group.find(1)

      expect(zammad.requests.last.on_behalf_of).to eq('agent@example.com')
    end

    it 'leaves on_behalf_of nil for an unscoped client' do
      client.group.find(1)

      expect(zammad.requests.last.on_behalf_of).to be_nil
    end

    it 'records a request that was not stubbed, so the failure can be inspected' do
      expect { client.group.find(2) }.to raise_error(described_class::UnstubbedRequestError)
      expect(zammad.requests.map(&:path)).to eq(['api/v1/groups/2'])
    end

    it 'hands out a frozen list' do
      expect { zammad.requests << :nonsense }.to raise_error(FrozenError)
    end

    it 'is recorded from several threads without losing any' do
      threads = Array.new(4) { Thread.new { 5.times { client.group.find(1) } } }
      threads.each(&:join)

      expect(zammad.requests.size).to eq(20)
    end
  end

  describe '#reset' do
    it 'forgets the stubs' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
      zammad.reset

      expect { client.group.find(1) }.to raise_error(described_class::UnstubbedRequestError)
    end

    it 'forgets the recorded requests' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
      client.group.find(1)

      expect(zammad.reset.requests).to be_empty
    end
  end

  describe '#inspect' do
    it 'reports the stubs and the requests' do
      zammad.stub(:get, 'api/v1/groups', body: [])
      client.group.all.to_a

      expect(zammad.inspect).to eq('#<ZammadAPI::Test stubbed=1 requests=1>')
    end
  end
end
