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

    it 'reports the very configuration the stand-in was built with' do
      expect(client.config).to be(zammad.config)
    end

    # Going through Client.new assembled a Faraday stack - auth, JSON,
    # retries, adapter - only for it to be swapped straight back out, once per
    # stand-in.
    it 'builds no HTTP stack on the way to the stand-in transport' do
      allow(ZammadAPI::Transport).to receive(:new).and_call_original

      described_class.new

      expect(ZammadAPI::Transport).not_to have_received(:new)
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

        expect(zammad.client.with(timeout: 5).group.find(1).name).to eq('Support')
        expect(a_request(:any, //)).not_to have_been_made
      end

      it 'reports the derived option' do
        expect(zammad.client.with(timeout: 5).config.timeout).to eq(5)
      end

      it 'keeps an on_behalf_of scope' do
        zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 })
        zammad.client.on_behalf_of('agent@example.com').with(timeout: 5).group.find(1)

        expect(zammad.requests.last.on_behalf_of).to eq('agent@example.com')
      end
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
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }], query: { page: 1 })
      zammad.stub(:get, 'api/v1/groups', body: [], query: { page: 2 })

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

    # The stand-in exists so that the code under test cannot tell it from the
    # real transport, and it carried its own copy of the verb loop - so a fifth
    # verb added to one would have left the other unable to answer it.
    it 'answers every verb the real transport answers' do
      expect(ZammadAPI::Test::Transport.new(zammad))
        .to respond_to(*ZammadAPI::Transport::Verbs.instance_methods)
    end

    # Transport#decode always hands over a response whose headers name the
    # type - it is what the decode branches on - while this set `json: true`
    # directly and left the headers as written. Code that branches on
    # `response.headers['content-type']` passed against Zammad and failed
    # against the stand-in, or the reverse.
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

    # The header used to be decorative: `json:` came from the Ruby type of the
    # stub's body, so a stub could say `text/html` and still hand back a
    # decoded Hash, where Zammad gives the raw string and `decoded` raises.
    context 'when a stub declares a type that is not JSON' do
      before { zammad.stub(:get, 'api/v1/groups/1', body: { id: 1 }, headers: { 'Content-Type' => 'text/html' }) }

      it 'does not decode the body' do
        expect(client.get('api/v1/groups/1')).not_to be_json
      end

      it 'hands back the raw body Zammad would have sent' do
        expect(client.get('api/v1/groups/1').body).to eq('{"id":1}')
      end

      it 'fails the way a real one would when a record is read from it' do
        expect { client.group.find(1) }.to raise_error(ZammadAPI::ParseError)
      end
    end

    # A nil Content-Type stringified to '', which then beat the JSON default
    # this kit supplies and served a Hash body undecoded - so the test failed
    # inside the code under test with nothing to say the stub was at fault.
    it 'refuses two spellings of one header rather than dropping a value' do
      expect { zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'Content-Type' => 'text/html', 'content-type' => 'application/json' }) }
        .to raise_error(ArgumentError, /header content-type was given twice/)
    end

    it 'refuses a header value the wire could not carry' do
      expect { zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'Content-Type' => nil }) }
        .to raise_error(ArgumentError, /header Content-Type was stubbed as nil/)
    end

    it 'names what a response header has to be' do
      expect { zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => [7] }) }
        .to raise_error(ArgumentError, /a response header is always text: pass a String/)
    end

    # Only the name used to be normalised, so a count written as an Integer
    # reached the code under test as one, where the wire always carries "7".
    it 'carries a header value as the String the wire would have sent' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => 7 })

      expect(client.get('api/v1/groups').headers['x-total-count']).to eq('7')
    end

    # Paging read the stub's body as written, which was the same thing only
    # while a list could arrive as an Array. Once the content-type decided
    # decoding, a list stubbed as a JSON string decoded to one and was never
    # paged, so it answered every page with the same records and every full
    # read raised PaginationError - where Zammad answers page two empty.
    it 'pages a list stubbed as a JSON string the way it pages an Array' do
      zammad.stub(:get, 'api/v1/groups', body: '[{"id":1,"name":"a"},{"id":2,"name":"b"}]', headers: { 'Content-Type' => 'application/json' })

      expect(client.group.all.map(&:name)).to eq(%w[a b])
    end

    it 'answers a later page of a string-bodied list as an endpoint out of records would' do
      zammad.stub(:get, 'api/v1/groups', body: '[{"id":1}]', headers: { 'Content-Type' => 'application/json' })

      expect(client.get('api/v1/groups', query: { page: 2 }).body).to eq([])
    end

    it 'keeps the raw body of a page it did not replace' do
      zammad.stub(:get, 'api/v1/groups/1', body: '{"id":1}', headers: { 'Content-Type' => 'application/json' })

      expect(client.get('api/v1/groups/1').raw_body).to eq('{"id":1}')
    end

    it 'decodes a string body a stub declares as JSON' do
      zammad.stub(:get, 'api/v1/groups/1', body: '{"id":1,"name":"Users"}', headers: { 'Content-Type' => 'application/json' })

      expect(client.group.find(1).name).to eq('Users')
    end

    it 'claims no content-type for a body it does not serve as JSON' do
      zammad.stub(:get, 'api/v1/groups/1/avatar', body: 'binary')

      expect(client.get('api/v1/groups/1/avatar').headers).not_to have_key('content-type')
    end

    # The stub keeps serving after a response is built, and Response is a
    # value. Handing out the stub's own Hash made every response from one stub
    # share it, so writing to `response.headers` in one example rewrote the
    # stand-in for every later request in it.
    it 'gives each response its own headers rather than the stub\'s' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => '7' })

      first  = client.get('api/v1/groups')
      second = client.get('api/v1/groups')

      expect(first.headers).not_to be(second.headers)
    end

    it 'hands out headers a caller cannot write through' do
      zammad.stub(:get, 'api/v1/groups', body: [], headers: { 'X-Total-Count' => '7' })

      expect { client.get('api/v1/groups').headers['x-total-count'] = '999' }.to raise_error(FrozenError)
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
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { sort_by: 'name' })

        expect(client.group.where(sort_by: 'name').first.id).to eq(1)
      end

      it 'does not answer a request without those parameters' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { sort_by: 'name' })

        expect { client.group.all.to_a }.to raise_error(described_class::UnstubbedRequestError)
      end

      it 'ignores the parameters the client adds itself' do
        zammad.stub(:get, 'api/v1/groups', body: [], query: { sort_by: 'name' })

        expect { client.group.where(sort_by: 'name').to_a }.not_to raise_error
      end

      it 'keeps answering when a catch-all for the same endpoint follows it' do
        zammad.stub(:get, 'api/v1/groups/search', body: { total_count: 42 }, query: { only_total_count: true })
        zammad.stub(:get, 'api/v1/groups/search', body: [{ id: 1 }])

        expect(Array.new(3) { client.group.search('x').count }).to eq([42, 42, 42])
      end

      it 'leaves the catch-all answering the requests it does not match' do
        zammad.stub(:get, 'api/v1/groups/search', body: { total_count: 42 }, query: { only_total_count: true })
        zammad.stub(:get, 'api/v1/groups/search', body: [], query: { page: 2 })
        zammad.stub(:get, 'api/v1/groups/search', body: [{ id: 1 }])

        expect(client.group.search('x').count).to eq(42)
        expect(client.group.search('x').map(&:id)).to eq([1])
        expect(client.group.search('x').count).to eq(42)
      end

      it 'matches an array-valued parameter' do
        zammad.stub(:get, 'api/v1/users/search', body: [{ id: 1 }], query: { ids: [1, 2], page: 1 })
        zammad.stub(:get, 'api/v1/users/search', body: [], query: { ids: [1, 2], page: 2 })

        expect(client.user.search('x').where(ids: [1, 2]).map(&:id)).to eq([1])
      end

      it 'reports a nil query value against the stub that wrote it' do
        expect { zammad.stub(:get, 'api/v1/users/search', body: [], query: { ids: nil }) }
          .to raise_error(ArgumentError, /query parameter ids is nil/)
      end

      it 'does not match an array whose values differ' do
        zammad.stub(:get, 'api/v1/users/search', body: [{ id: 1 }], query: { ids: [1, 2] })

        expect { client.user.search('x').where(ids: [3]).to_a }
          .to raise_error(described_class::UnstubbedRequestError)
      end

      it 'answers ahead of a catch-all declared before it' do
        zammad.stub(:get, 'api/v1/groups/search', body: [{ id: 1 }])
        zammad.stub(:get, 'api/v1/groups/search', body: { total_count: 42 }, query: { only_total_count: true })

        expect(client.group.search('x').count).to eq(42)
      end

      it 'still sequences two stubs that share a scope' do
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }], query: { sort_by: 'name' })
        zammad.stub(:get, 'api/v1/groups', body: [{ id: 2 }], query: { sort_by: 'name' })

        expect(client.group.all.where(sort_by: 'name').page(1, per_page: 1).map(&:id)).to eq([1])
        expect(client.group.all.where(sort_by: 'name').page(1, per_page: 1).map(&:id)).to eq([2])
        expect(client.group.all.where(sort_by: 'name').page(1, per_page: 1).map(&:id)).to eq([2])
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

    it 'is outside ZammadAPI::Error, so code under test cannot rescue it as an API failure' do
      expect(described_class::UnstubbedRequestError.ancestors).not_to include(ZammadAPI::Error)
      expect(described_class::UnstubbedRequestError.ancestors).to include(StandardError)
    end

    it 'escapes a rescue of the gem\'s errors, the way the examples write one' do
      zammad.stub(:get, 'api/v1/groups/2', body: { id: 2 })

      caller_with_a_rescue = lambda do
        client.group.find(1)
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
      client.group.find(1)

      expect(zammad.requests.last.verb).to eq(:get)
      expect(zammad.requests.last.path).to eq('api/v1/groups/1')
    end

    it 'records only what a save actually sends' do
      client.group.find(1).update!(name: 'Renamed')

      expect(zammad.requests.last.body).to eq({ name: 'Renamed' })
    end

    # Recorded by reference, a test that built one payload, sent it, then
    # changed it for a second call rewrote the first recorded request and
    # asserted against a body that never went anywhere.
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

    it 'records the query parameters the client sent' do
      client.group.find(1)

      expect(zammad.requests.last.query).to eq({ 'expand' => 'true' })
    end

    it 'records them stringified, the way the transport sends them' do
      zammad.stub(:get, 'api/v1/groups', body: [{ id: 1 }])
      client.group.all.page(2, per_page: 50).to_a

      expect(zammad.requests.last.query)
        .to eq({ 'expand' => 'true', 'page' => '2', 'per_page' => '50' })
    end

    it 'rejects a nil query value the way the transport does' do
      expect { client.group.where(sort_by: nil).to_a }
        .to raise_error(ArgumentError, /query parameter sort_by is nil/)
    end

    it 'records requests oldest first' do
      client.group.find(1).update!(name: 'Renamed')

      expect(zammad.requests.map(&:verb)).to eq(%i[get put])
    end

    it 'records an on_behalf_of scope' do
      client.on_behalf_of('agent@example.com').group.find(1)

      expect(zammad.requests.last.on_behalf_of).to eq('agent@example.com')
    end

    it 'records an integer user id the way the wire carries it' do
      client.on_behalf_of(42).group.find(1)

      expect(zammad.requests.last.on_behalf_of).to eq('42')
    end

    it 'leaves on_behalf_of nil for an unscoped client' do
      client.group.find(1)

      expect(zammad.requests.last.on_behalf_of).to be_nil
    end

    # Through the real transport's own rules, so that a stand-in cannot accept
    # a header the wire would refuse or record it in a shape the wire would
    # not carry.
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
      client.group.find(1)

      expect(zammad.requests.last.headers).to eq({})
    end

    it 'refuses a header the real transport would refuse' do
      expect { client.get('api/v1/roles', headers: { 'Authorization' => 'Token other' }) }
        .to raise_error(ArgumentError, /header authorization is set by this client/)
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

    # The request count used to be read outside the monitor, so printing a
    # stand-in from a failure message or a debugger raced a thread under test
    # appending to it - which is the one thing the monitor is here to prevent.
    it 'reads the recorded requests under the monitor' do
      zammad.stub(:get, 'api/v1/groups', body: [])
      writers = Array.new(4) { Thread.new { 25.times { client.group.all.to_a } } }
      readers = Array.new(4) { Thread.new { 25.times { zammad.inspect } } }

      expect { (writers + readers).each(&:join) }.not_to raise_error
      expect(zammad.requests.size).to eq(100)
    end
  end

  # A collection walks until a page repeats, comes back short, or comes back
  # empty. A stub that served the same records to every page tripped the
  # first of those, so the obvious way to stand in for a list endpoint made
  # every full read of it raise PaginationError - against a real Zammad the
  # same code works, because page 2 comes back empty.
  describe 'a list endpoint stubbed once' do
    subject(:zammad) { described_class.new }

    let(:client) { zammad.client }

    before { zammad.stub(:get, 'api/v1/groups', body: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }]) }

    it 'reads the whole collection without a second stub' do
      expect(client.group.all.map(&:id)).to eq([1, 2])
    end

    it 'counts it' do
      expect(client.group.all.count).to eq(2)
    end

    it 'plucks from it' do
      expect(client.group.all.pluck(:name)).to eq(%w[a b])
    end

    it 'answers page 1 with the records it holds' do
      expect(client.group.all.page(1).map(&:id)).to eq([1, 2])
    end

    it 'answers a later page as an endpoint out of records would' do
      expect(client.group.all.page(2).map(&:id)).to eq([])
    end

    it 'stops walking rather than reporting the stand-in as a broken paginator' do
      expect { client.group.all.to_a }.not_to raise_error
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

      expect(client.group.all.map(&:id)).to eq([1, 2])
    end

    it 'keeps a body that is not a list alone' do
      zammad.stub(:get, 'api/v1/groups/1', body: { id: 1, name: 'a' })

      expect(client.group.find(1).name).to eq('a')
    end
  end

  # Two stubs naming different parameters both match a request carrying all of
  # them. Grouped only by whether they were scoped at all, they were read as a
  # sequence and the first was consumed: the count ate the records stub,
  # handed back an Array where a count belonged, and then reported the
  # endpoint as unstubbed.
  describe 'two stubs that describe one request equally well' do
    subject(:zammad) { described_class.new }

    let(:client) { zammad.client }

    before do
      zammad.stub(:get, 'api/v1/tickets/search', body: [{ id: 1 }], query: { query: 'foo' })
      zammad.stub(:get, 'api/v1/tickets/search', body: { total_count: 2 }, query: { only_total_count: true })
    end

    it 'refuses to guess which one was meant' do
      expect { client.ticket.search('foo').count }.to raise_error(described_class::AmbiguousStubError)
    end

    it 'names both scopes, so the fix is visible from the message' do
      expect { client.ticket.search('foo').count }
        .to raise_error(described_class::AmbiguousStubError, /only_total_count.*|.*only_total_count/)
    end

    it 'says the test is wrong rather than that Zammad refused something' do
      expect(described_class::AmbiguousStubError.ancestors).not_to include(ZammadAPI::Error)
    end

    it 'answers the request a more specific stub names' do
      zammad.reset
      zammad.stub(:get, 'api/v1/tickets/search', body: [{ id: 1 }], query: { query: 'foo' })
      zammad.stub(:get, 'api/v1/tickets/search', body: { total_count: 2 }, query: { query: 'foo', only_total_count: true })

      expect(client.ticket.search('foo').count).to eq(2)
    end

    it 'leaves the less specific stub answering the requests it alone matches' do
      zammad.reset
      zammad.stub(:get, 'api/v1/tickets/search', body: [{ id: 1 }], query: { query: 'foo' })
      zammad.stub(:get, 'api/v1/tickets/search', body: { total_count: 2 }, query: { query: 'foo', only_total_count: true })

      expect(client.ticket.search('foo').map(&:id)).to eq([1])
    end
  end
end
