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
      client.groups.find(1)

      expect(a_request(:any, //)).not_to have_been_made
    end

    it 'reports the stand-in configuration' do
      expect(client.config.url).to eq('https://zammad.test/')
    end

    # The stand-in carries a token of its own, so credentials handed to it
    # replace that one rather than being refused as a second scheme.
    it 'accepts credentials of another kind in place of its own token' do
      zammad = described_class.new(user: 'u', password: 'p')
      expect(zammad.client.config.authentication_scheme).to eq(:basic)
    end

    it 'accepts configuration overrides' do
      expect(described_class.new(url: 'https://other.test/').client.config.url).to eq('https://other.test/')
    end

    describe 'a client derived with #with' do
      it 'still answers from the stand-in instead of opening a connection' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Support' })

        expect(zammad.client.with(timeout: 5).groups.find(1).name).to eq('Support')
        expect(a_request(:any, //)).not_to have_been_made
      end

      it 'reports the derived option' do
        expect(zammad.client.with(timeout: 5).config.timeout).to eq(5)
      end

      it 'keeps an on_behalf_of scope' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
        zammad.client.on_behalf_of('agent@example.com').with(timeout: 5).groups.find(1)

        expect(zammad.requests.last.on_behalf_of).to eq('agent@example.com')
      end

      it 'keeps the derived options under an on_behalf_of scope taken afterwards' do
        expect(zammad.client.with(timeout: 5).on_behalf_of('agent@example.com').config.timeout).to eq(5)
      end
    end
  end

  describe '#stub' do
    it 'answers a find with a record' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })

      expect(client.groups.find(1).name).to eq('Users')
    end

    it 'answers a collection with every page' do
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }], query: { page: 1 })
      zammad.stub(:get, 'api/v1/groups', body: [], query: { page: 2 })

      expect(client.groups.pluck(:name)).to eq(%w[Users Support])
    end

    it 'ignores a leading slash on the stub' do
      zammad.stub(:get, '/api/v1/groups/1', body: { id: 1 })

      expect(client.groups.find(1).id).to eq(1)
    end

    # The real transport refuses this, so a stand-in that answered it would
    # let a test pass over a request production never sends.
    it 'refuses an absolute URL the way the real transport does' do
      expect { client.get('https://other.example/collect') }
        .to raise_error(ArgumentError, /a request path is relative to the instance URL/)
    end

    it 'raises the mapped error class for a non-2xx status' do
      zammad.stub(:get, 'api/v1/groups/1', status: 404, body: { error: 'not found' })

      expect { client.groups.find(1) }.to raise_error(ZammadAPI::NotFoundError, /not found/)
    end

    it 'raises a rate limit with the wait Zammad asked for' do
      zammad.stub(:get, 'api/v1/groups/1', status: 429, headers: { 'Retry-After' => '30' })

      expect { client.groups.find(1) }.to raise_error(ZammadAPI::RateLimitError) { expect(it.retry_after).to eq(30) }
    end

    it 'serves a non-JSON body untouched, e.g. an attachment' do
      zammad.stub(:get, 'api/v1/ticket_attachment/1/2/3', body: 'binary-ish')

      attachment = ZammadAPI::Resources::TicketArticleAttachment
        .new(zammad.client.instance_variable_get(:@transport), id: 3, ticket_id: 1, article_id: 2)

      expect(attachment.download).to eq('binary-ish')
    end

    it 'returns itself, so stubs can be chained' do
      expect(zammad.stub(:get, 'api/v1/groups', body: [])).to be(zammad)
    end

    it 'exposes response headers' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => '7' })

      expect(client.get('api/v1/groups').headers['x-total-count']).to eq('7')
    end

    it 'serves a JSON body with the content-type a real response carries' do
      zammad.stub(:get, 'api/v1/groups', body: [])

      expect(client.get('api/v1/groups').headers['content-type']).to eq('application/json')
    end

    it 'lets a test say the endpoint answered with something else' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'Content-Type' => 'application/json; charset=utf-8' })

      expect(client.get('api/v1/groups').headers['content-type']).to eq('application/json; charset=utf-8')
    end

    context 'when a stub declares a type that is not JSON' do
      before { zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 }, headers: { 'Content-Type' => 'text/html' }) }

      it 'hands back the raw body Zammad would have sent' do
        expect(client.get('api/v1/groups/1').body).to eq('{"id":1}')
      end
    end

    it 'carries a header value as the String the wire would have sent' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => 7 })

      expect(client.get('api/v1/groups').headers['x-total-count']).to eq('7')
    end

    it 'decodes a string body a stub declares as JSON' do
      zammad.stub(:get, 'api/v1/groups/1', body: '{"id":1,"name":"Users"}', headers: { 'Content-Type' => 'application/json' })

      expect(client.groups.find(1).name).to eq('Users')
    end

    it 'claims no content-type for a body it does not serve as JSON' do
      zammad.stub(:get, 'api/v1/groups/1/avatar', body: 'binary')

      expect(client.get('api/v1/groups/1/avatar').headers).not_to have_key('content-type')
    end

    it 'hands out headers a caller cannot write through' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => '7' })

      expect { client.get('api/v1/groups').headers['x-total-count'] = '999' }.to raise_error(FrozenError)
    end

    describe 'a sequence' do
      it 'serves stubs in the order they were declared' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'First' })
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Second' })

        expect(client.groups.find(1).name).to eq('First')
        expect(client.groups.find(1).name).to eq('Second')
      end

      it 'keeps answering with the last one' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'First' })
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Second' })

        3.times { client.groups.find(1) }
        expect(client.groups.find(1).name).to eq('Second')
      end
    end

    describe 'query matching' do
      it 'matches a stub that names a subset of the parameters' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { sort_by: 'name' })

        expect(client.groups.order(:name).first.id).to eq(1)
      end

      it 'does not answer a request without those parameters' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { sort_by: 'name' })

        expect { client.groups.all.to_a }.to raise_error(described_class::UnstubbedRequestError)
      end

      it 'matches an array-valued parameter' do
        zammad.stub(:get, 'api/v1/users/search', body: [{ id: 1 }], query: { ids: [1, 2], page: 1 })
        zammad.stub(:get, 'api/v1/users/search', body: [], query: { ids: [1, 2], page: 2 })

        expect(client.users.search('x', ids: [1, 2]).map(&:id)).to eq([1])
      end

      it 'answers a search count from a stub for the request for the total' do
        zammad.stub(:get, 'api/v1/groups/search', body: { total_count: 42 }, query: { only_total_count: true })

        expect(client.groups.search('x').count).to eq(42)
        expect(zammad.requests.size).to eq(1)
      end

      it 'sequences two stubs that share a scope' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { sort_by: 'name' })
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 2 }], query: { sort_by: 'name' })

        expect(Array.new(3) { client.groups.all.order(:name).page(1, per_page: 1).map(&:id) }).to eq([[1], [2], [2]])
      end

      it 'spends the first matching stub where a later one matches too' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { sort_by: 'name' })
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 2 }])

        expect(Array.new(3) { client.get('api/v1/groups', query: { sort_by: 'name' }).body }).to eq([[{ id: 1 }], [{ id: 2 }], [{ id: 2 }]])
      end
    end
  end

  describe 'an unstubbed request' do
    it 'names the request that was not stubbed' do
      expect { client.groups.find(1) }
        .to raise_error(described_class::UnstubbedRequestError, 'GET api/v1/groups/1 with query {"expand" => "true"} was not stubbed on this ZammadAPI::Test (nothing is stubbed)')
    end

    it 'lists what is stubbed, because a wrong path is the usual cause' do
      zammad.stub(:get, 'api/v1/groups/2', body: { id: 2 })

      expect { client.groups.find(1) }.to raise_error(%r{stubbed: GET api/v1/groups/2})
    end

    it 'is outside ZammadAPI::Error, so code under test cannot rescue it as an API failure' do
      expect(described_class::UnstubbedRequestError.ancestors).not_to include(ZammadAPI::Error)
      expect(described_class::UnstubbedRequestError.ancestors).to include(StandardError)
    end
  end

  describe '#requests' do
    before do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })
      zammad.stub(:put, 'api/v1/groups/1', body: { id: 1, name: 'Renamed' })
    end

    it 'records the verb and path' do
      client.groups.find(1)

      expect(zammad.requests.last.verb).to eq(:get)
      expect(zammad.requests.last.path).to eq('api/v1/groups/1')
    end

    it 'records only what a save actually sends' do
      client.groups.find(1).update!(name: 'Renamed')

      expect(zammad.requests.last.body).to eq({ name: 'Renamed' })
    end

    it 'records the body as it was sent, not as the test left it afterwards' do
      zammad.stub(:post, 'api/v1/groups', body: { id: 2 })
      payload = { name: 'Support', note: { internal: 'yes' } }
      client.post('api/v1/groups', body: payload)

      payload[:name] = 'Mutated'
      payload[:note][:internal] = 'no'

      expect(zammad.requests.last.body).to eq({ name: 'Support', note: { internal: 'yes' } })
    end

    it 'records the query parameters the client sent' do
      client.groups.find(1)

      expect(zammad.requests.last.query).to eq({ 'expand' => 'true' })
    end

    it 'records them stringified, the way the transport sends them' do
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }])
      client.groups.all.page(2, per_page: 50).to_a

      expect(zammad.requests.last.query)
        .to eq({ 'expand' => 'true', 'page' => '2', 'per_page' => '50' })
    end

    it 'records a nested query stringified throughout' do
      zammad.stub(:get, 'api/v1/roles', body: [])
      client.get('api/v1/roles', query: { ids: [1, 2], filter: { active: true } })

      expect(zammad.requests.last.query).to eq('ids' => %w[1 2], 'filter' => { 'active' => 'true' })
    end

    it 'records requests oldest first' do
      client.groups.find(1).update!(name: 'Renamed')

      expect(zammad.requests.map(&:verb)).to eq(%i[get put])
    end

    it 'records an on_behalf_of scope' do
      client.on_behalf_of('agent@example.com').groups.find(1)

      expect(zammad.requests.last.on_behalf_of).to eq('agent@example.com')
    end

    it 'leaves on_behalf_of nil for an unscoped client' do
      client.groups.find(1)

      expect(zammad.requests.last.on_behalf_of).to be_nil
    end

    it 'records the headers a raw request asked for' do
      zammad.stub(:get, 'api/v1/roles', body: [])
      client.get('api/v1/roles', headers: { 'Accept-Language' => 'de-de' })

      expect(zammad.requests.last.headers).to include('accept-language' => 'de-de')
    end

    it 'records a header value the way the wire would carry it' do
      zammad.stub(:get, 'api/v1/roles', body: [])
      client.get('api/v1/roles', headers: { 'X-Retry' => 3 })

      expect(zammad.requests.last.headers).to include('x-retry' => '3')
    end

    it 'records the headers the client sends by itself' do
      client.groups.find(1)

      expect(zammad.requests.last.headers).to include('accept' => 'application/json', 'authorization' => 'Token test-token')
    end

    it 'records a request that was not stubbed, so the failure can be inspected' do
      expect { client.groups.find(2) }.to raise_error(described_class::UnstubbedRequestError)
      expect(zammad.requests.map(&:path)).to eq(['api/v1/groups/2'])
    end

    it 'hands out a frozen list' do
      expect { zammad.requests << :nonsense }.to raise_error(FrozenError)
    end

    it 'is recorded from several threads without losing any' do
      threads = Array.new(4) { Thread.new { 5.times { client.groups.find(1) } } }
      threads.each(&:join)

      expect(zammad.requests.size).to eq(20)
    end
  end

  describe '#reset' do
    it 'forgets the stubs' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
      zammad.reset

      expect { client.groups.find(1) }.to raise_error(described_class::UnstubbedRequestError)
    end

    it 'forgets the recorded requests' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
      client.groups.find(1)

      expect(zammad.reset.requests).to be_empty
    end
  end

  describe '#inspect' do
    it 'reports the stubs and the requests' do
      zammad.stub(:get, 'api/v1/groups', body: [])
      client.groups.all.to_a

      expect(zammad.inspect).to eq('#<ZammadAPI::Test stubbed=1 requests=1>')
    end

    it 'reads the recorded requests under the monitor' do
      zammad.stub(:get, 'api/v1/groups', body: [])
      writers = Array.new(4) { Thread.new { 25.times { client.groups.all.to_a } } }
      readers = Array.new(4) { Thread.new { 25.times { zammad.inspect } } }

      expect { (writers + readers).each(&:join) }.not_to raise_error
      expect(zammad.requests.size).to eq(100)
    end
  end

  describe 'a list endpoint stubbed once' do
    subject(:zammad) { described_class.new }

    let(:client) { zammad.client }

    before { zammad.stub(:get, 'api/v1/groups', body: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }]) }

    it 'reads the whole collection without a second stub' do
      expect(client.groups.all.map(&:id)).to eq([1, 2])
    end

    it 'answers a later page as an endpoint out of records would' do
      expect(client.groups.all.page(2).map(&:id)).to eq([])
    end
  end

  describe 'a list endpoint stubbed as a sequence' do
    subject(:zammad) { described_class.new }

    let(:client) { zammad.client }

    def names = client.groups.all.map(&:name)

    before do
      %w[A B C].each { zammad.stub(:get, 'api/v1/groups', body: [{ id: 1, name: it }]) }
    end

    it 'answers each read with the next stub' do
      expect(Array.new(3) { names }).to eq([['A'], ['B'], ['C']])
    end

    it 'spends one stub on a read, however many pages the read asks for' do
      expect(client.groups.find_each(batch_size: 1).map(&:name)).to eq(['A'])
      expect(zammad.requests.map { it.query['page'] }).to eq(%w[1 2])
      expect(names).to eq(['B'])
    end
  end

  describe 'a list endpoint whose pages are stubbed by hand' do
    subject(:zammad) { described_class.new }

    let(:client) { zammad.client }

    # A stub that names a page is left exactly as written - that is how a test
    # says what the second page holds.
    it 'serves each page as declared' do
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { page: 1 })
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 2 }], query: { page: 2 })
      zammad.stub(:get, 'api/v1/groups', body: [], query: { page: 3 })

      expect(client.groups.find_each(batch_size: 1).map(&:id)).to eq([1, 2])
    end
  end
end
