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

    it 'reports the very configuration the stand-in was built with' do
      expect(client.config).to be(zammad.config)
    end

    it 'builds no HTTP stack on the way to the stand-in transport' do
      allow(ZammadAPI::Transport).to receive(:new).and_call_original

      described_class.new

      expect(ZammadAPI::Transport).not_to have_received(:new)
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

    it 'is the same client every time, rather than a new HTTP stack per call' do
      expect(zammad.client).to equal(zammad.client)
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

      it 'still takes two records found through the same derived client as one' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
        derived = zammad.client.with(timeout: 5)
        found   = derived.groups.find(1)

        expect(derived.groups.find(1)).to eq(found)
      end
    end
  end

  describe '#stub' do
    it 'answers a find with a record' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })

      expect(client.groups.find(1).name).to eq('Users')
    end

    it 'builds records that behave like fetched ones' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })

      group = client.groups.find(1)
      expect(group).to be_persisted
      expect { group.attributes[:name] = 'x' }.to raise_error(FrozenError)
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

    it 'records nothing for a path it refuses' do
      expect { client.get('https://other.example/collect') }.to raise_error(ArgumentError)
      expect(zammad.requests).to be_empty
    end

    it 'raises the mapped error class for a non-2xx status' do
      zammad.stub(:get, 'api/v1/groups/1', status: 404, body: { error: 'not found' })

      expect { client.groups.find(1) }.to raise_error(ZammadAPI::NotFoundError, /not found/)
    end

    it 'raises a validation error that save reports as false' do
      zammad.stub(:post, 'api/v1/groups', status: 422, body: { error: 'Name is required' })

      group = client.groups.new(name: '')
      expect(group.save).to be(false)
      expect(group.error.server_message).to eq('Name is required')
    end

    it 'raises a rate limit with the wait Zammad asked for' do
      zammad.stub(:get, 'api/v1/groups/1', status: 429, headers: { 'Retry-After' => '30' })

      expect { client.groups.find(1) }.to raise_error(ZammadAPI::RateLimitError) { expect(it.retry_after).to eq(30) }
    end

    it 'raises for a failure at once, without the retries the real transport makes' do
      zammad.stub(:get, 'api/v1/groups/1', status: 503)
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })

      expect { client.groups.find(1) }.to raise_error(ZammadAPI::ServerError)
      expect(zammad.requests.size).to eq(1)
    end

    it 'serves a non-JSON body untouched, e.g. an attachment' do
      zammad.stub(:get, 'api/v1/ticket_attachment/1/2/3', body: 'binary-ish')

      attachment = ZammadAPI::Resources::TicketArticleAttachment
        .new(zammad.client.tickets.new.transport, id: 3, ticket_id: 1, article_id: 2)

      expect(attachment.download).to eq('binary-ish')
    end

    it 'returns itself, so stubs can be chained' do
      expect(zammad.stub(:get, 'api/v1/groups', body: [])).to be(zammad)
    end

    it 'accepts string keys in the body' do
      zammad.stub(:get, 'api/v1/groups/1', body: { 'id' => 1, 'name' => 'Users' })

      expect(client.groups.find(1).name).to eq('Users')
    end

    it 'exposes response headers' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => '7' })

      expect(client.get('api/v1/groups').headers['x-total-count']).to eq('7')
    end

    it 'answers every verb the real transport answers' do
      expect(ZammadAPI::Test::Transport.new(zammad))
        .to respond_to(*ZammadAPI::Transport::Verbs.instance_methods)
    end

    it 'serves a JSON body with the content-type a real response carries' do
      zammad.stub(:get, 'api/v1/groups', body: [])

      expect(client.get('api/v1/groups').headers['content-type']).to eq('application/json')
    end

    it 'serves an object body with the same content-type' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })

      expect(client.get('api/v1/groups/1').headers['content-type']).to eq('application/json')
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

      it 'fails the way a real one would when a record is read from it' do
        expect { client.groups.find(1) }.to raise_error(ZammadAPI::ParseError)
      end
    end

    it 'carries a header value as the String the wire would have sent' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => 7 })

      expect(client.get('api/v1/groups').headers['x-total-count']).to eq('7')
    end

    it 'reads a list stubbed as a JSON string' do
      zammad.stub(:get, 'api/v1/groups', body: '[{"id":1,"name":"a"},{"id":2,"name":"b"}]', headers: { 'Content-Type' => 'application/json' })

      expect(client.groups.all.map(&:name)).to eq(%w[a b])
    end

    it 'keeps the raw body of a page it did not replace' do
      zammad.stub(:get, 'api/v1/groups/1', body: '{"id":1}', headers: { 'Content-Type' => 'application/json' })

      expect(client.get('api/v1/groups/1').raw_body).to eq('{"id":1}')
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

      it 'reuses a single stub for any number of requests' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'Users' })

        expect(Array.new(3) { client.groups.find(1).name }).to eq(%w[Users Users Users])
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

      it 'ignores the parameters the client adds itself' do
        zammad.stub(:get, 'api/v1/groups', body: [], query: { sort_by: 'name' })

        expect { client.groups.order(:name).to_a }.not_to raise_error
      end

      it 'matches an array-valued parameter' do
        zammad.stub(:get, 'api/v1/users/search', body: [{ id: 1 }], query: { ids: [1, 2], page: 1 })
        zammad.stub(:get, 'api/v1/users/search', body: [], query: { ids: [1, 2], page: 2 })

        expect(client.users.search('x', ids: [1, 2]).map(&:id)).to eq([1])
      end

      it 'does not match an array whose values differ' do
        zammad.stub(:get, 'api/v1/users/search', body: [{ id: 1 }], query: { ids: [1, 2] })

        expect { client.users.search('x', ids: [3]).to_a }
          .to raise_error(described_class::UnstubbedRequestError)
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
    it 'raises rather than returning something empty' do
      expect { client.groups.find(1) }.to raise_error(described_class::UnstubbedRequestError)
    end

    it 'names the request that was not stubbed' do
      expect { client.groups.find(1) }
        .to raise_error(described_class::UnstubbedRequestError, 'GET api/v1/groups/1 with query {"expand" => "true"} was not stubbed on this ZammadAPI::Test (nothing is stubbed)')
    end

    it 'says so when nothing at all is stubbed' do
      expect { client.groups.find(1) }.to raise_error(/nothing is stubbed/)
    end

    it 'lists what is stubbed, because a wrong path is the usual cause' do
      zammad.stub(:get, 'api/v1/groups/2', body: { id: 2 })

      expect { client.groups.find(1) }.to raise_error(%r{stubbed: GET api/v1/groups/2})
    end

    it 'names the query of a request for a page no stub answers' do
      zammad.stub(:get, 'api/v1/users/search', body: [{ id: 1 }], query: { page: 1 })
      zammad.stub(:get, 'api/v1/users/search', body: [{ id: 2 }], query: { page: 2 })

      expect { client.users.search('x').to_a }.to raise_error(
        described_class::UnstubbedRequestError,
        %r{\AGET api/v1/users/search with query \{.*"page" => "3".*\} was not stubbed on this ZammadAPI::Test \(stubbed: GET api/v1/users/search\)\z}
      )
    end

    it 'is outside ZammadAPI::Error, so code under test cannot rescue it as an API failure' do
      expect(described_class::UnstubbedRequestError.ancestors).not_to include(ZammadAPI::Error)
      expect(described_class::UnstubbedRequestError.ancestors).to include(StandardError)
    end

    it 'escapes a rescue of the gem\'s errors, the way the examples write one' do
      zammad.stub(:get, 'api/v1/groups/2', body: { id: 2 })

      caller_with_a_rescue = lambda do
        client.groups.find(1)
      rescue ZammadAPI::Error
        :handled_as_an_api_failure
      end

      expect { caller_with_a_rescue.call }.to raise_error(described_class::UnstubbedRequestError)
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

    it 'hands out a recorded body that cannot be written through' do
      zammad.stub(:post, 'api/v1/groups', body: { id: 2 })
      client.post('api/v1/groups', body: { name: 'Support' })

      expect(zammad.requests.last.body).to be_frozen
    end

    it 'records a record built from strong parameters as the attributes it sends' do
      zammad.stub(:post, 'api/v1/groups', body: { id: 2 })
      client.groups.create(StrongParameters.new(name: 'Support'))

      expect(zammad.requests.last.body).to eq({ name: 'Support' })
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

    it 'records an integer user id the way the wire carries it' do
      client.on_behalf_of(42).groups.find(1)

      expect(zammad.requests.last.on_behalf_of).to eq('42')
    end

    it 'records a scope that ends in a line break the way the wire carries it' do
      client.on_behalf_of("agent@example.com\n").groups.find(1)

      expect(zammad.requests.last.on_behalf_of).to eq('agent@example.com')
    end

    it 'records the scope a client was given, not what its string became afterwards' do
      login  = +'agent@example.com'
      scoped = client.on_behalf_of(login)
      login.replace('admin@example.com')
      scoped.groups.find(1)

      expect(zammad.requests.last.on_behalf_of).to eq('agent@example.com')
    end

    it 'leaves on_behalf_of nil for an unscoped client' do
      client.groups.find(1)

      expect(zammad.requests.last.on_behalf_of).to be_nil
    end

    it 'records the headers a raw request asked for' do
      zammad.stub(:get, 'api/v1/roles', body: [])
      client.get('api/v1/roles', headers: { 'Accept-Language' => 'de-de' })

      expect(zammad.requests.last.headers).to eq('accept-language' => 'de-de')
    end

    it 'records a header value the way the wire would carry it' do
      zammad.stub(:get, 'api/v1/roles', body: [])
      client.get('api/v1/roles', headers: { 'X-Retry' => 3 })

      expect(zammad.requests.last.headers).to eq('x-retry' => '3')
    end

    it 'leaves the headers empty for a request that named none' do
      client.groups.find(1)

      expect(zammad.requests.last.headers).to eq({})
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

  describe 'a list endpoint whose resource says it does not page' do
    let(:resource) do
      Class.new(ZammadAPI::Resources::Base) do
        def self.name = 'ObjectAttribute'

        path 'api/v1/object_manager_attributes'
        paginated false
      end
    end

    before { zammad.stub(:get, 'api/v1/object_manager_attributes', body: [{ id: 1, name: 'a' }]) }

    it 'is read from the one stub' do
      expect(client.resource(resource).map(&:name)).to eq(['a'])
    end

    it 'is recorded as the one request it is, naming no page' do
      client.resource(resource).to_a
      expect(zammad.requests.map(&:query)).to eq([{ 'expand' => 'true' }])
    end
  end

  describe 'a list endpoint stubbed once' do
    subject(:zammad) { described_class.new }

    let(:client) { zammad.client }

    before { zammad.stub(:get, 'api/v1/groups', body: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }]) }

    it 'reads the whole collection without a second stub' do
      expect(client.groups.all.map(&:id)).to eq([1, 2])
    end

    it 'counts it' do
      expect(client.groups.all.count).to eq(2)
    end

    it 'plucks from it' do
      expect(client.groups.all.pluck(:name)).to eq(%w[a b])
    end

    it 'answers page 1 with the records it holds' do
      expect(client.groups.all.page(1).map(&:id)).to eq([1, 2])
    end

    it 'answers a later page as an endpoint out of records would' do
      expect(client.groups.all.page(2).map(&:id)).to eq([])
    end

    it 'answers page 1 with every record it holds, whatever size was asked for' do
      expect(client.groups.all.page(1, per_page: 1).map(&:id)).to eq([1, 2])
    end

    it 'stops walking rather than reporting the stand-in as a broken paginator' do
      expect { client.groups.all.to_a }.not_to raise_error
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

    it 'keeps answering with the last one' do
      3.times { names }
      expect(names).to eq(['C'])
    end

    it 'spends one stub on a read, however many pages the read asks for' do
      expect(client.groups.find_each(batch_size: 1).map(&:name)).to eq(['A'])
      expect(zammad.requests.map { it.query['page'] }).to eq(%w[1 2])
      expect(names).to eq(['B'])
    end

    it 'does not spend a stub on a later page asked for first' do
      expect(client.groups.all.page(3).to_a).to eq([])
      expect(names).to eq(['A'])
    end

    it 'spends one stub on a read sized for a single record' do
      expect(Array.new(3) { client.groups.first.name }).to eq(%w[A B C])
    end

    it 'starts over after a reset' do
      names
      zammad.reset
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 2, name: 'D' }])

      expect(Array.new(2) { names }).to eq([['D'], ['D']])
    end

    it 'sequences a scoped list the same way' do
      zammad.reset
      %w[A B].each { zammad.stub(:get, 'api/v1/groups/search', body: [{ id: 1, name: it }], query: { query: 'x' }) }

      expect(Array.new(2) { client.groups.search('x').map(&:name) }).to eq([['A'], ['B']])
    end

    it 'answers the page after a list with an empty one, whatever stub is queued next' do
      zammad.reset
      zammad.stub(:get, 'api/v1/groups/search', body: [{ id: 1, name: 'A' }])
      zammad.stub(:get, 'api/v1/groups/search', status: 500)

      expect(client.groups.search('x').map(&:name)).to eq(['A'])
      expect { client.groups.search('x').to_a }.to raise_error(ZammadAPI::ServerError)
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

    it 'keeps a body that is not a list alone' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'a' })

      expect(client.groups.find(1).name).to eq('a')
    end
  end
end
