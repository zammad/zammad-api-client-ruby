# frozen_string_literal: true

RSpec.describe ZammadAPI::ResourceProxy do
  subject(:proxy) { client.group }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  it 'exposes the resource class' do
    expect(proxy.resource_class).to eq(ZammadAPI::Resources::Group)
  end

  describe '#new' do
    it 'builds an unsaved record' do
      expect(proxy.new(name: 'Support')).to be_new_record
    end

    it 'does not talk to the server' do
      proxy.new(name: 'Support')
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end

    it 'accepts no attributes at all' do
      expect(proxy.new.attributes).to eq({})
    end
  end

  describe '#find' do
    it 'requests the record with expanded attributes' do
      stub = stub_request(:get, "#{url}/1").with(query: { 'expand' => 'true' }).to_return(json_response({ id: 1, name: 'Users' }))

      proxy.find(1)
      expect(stub).to have_been_requested
    end

    it 'returns a persisted record' do
      stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, name: 'Users' }))

      expect(proxy.find(1)).to be_persisted
    end

    it 'maps the attributes' do
      stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, name: 'Users' }))

      expect(proxy.find(1).name).to eq('Users')
    end

    it 'raises NotFoundError for an unknown id' do
      stub_request(:get, "#{url}/404").with(query: hash_including({})).to_return(json_response({ error: 'not found' }, status: 404))

      expect { proxy.find(404) }.to raise_error(ZammadAPI::NotFoundError)
    end

    it 'raises ParseError when the response is not an object' do
      stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      expect { proxy.find(1) }.to raise_error(ZammadAPI::ParseError, /expected a JSON object, got Array/)
    end
  end

  describe 'ids in the request path' do
    it 'escapes a traversal instead of reaching another endpoint' do
      stub = stub_request(:get, "#{url}/1%2F..%2F..%2Fapi%2Fv1%2Fusers%2F1")
        .with(query: { 'expand' => 'true' })
        .to_return(json_response({ error: 'not found' }, status: 404))

      expect { proxy.find('1/../../api/v1/users/1') }.to raise_error(ZammadAPI::NotFoundError)
      expect(stub).to have_been_requested
      expect(a_request(:get, %r{/api/v1/users/1\z})).not_to have_been_made
    end

    it 'escapes the id on destroy too' do
      stub = stub_request(:delete, "#{url}/1%2F..%2F..%2Fapi%2Fv1%2Fusers%2F1").to_return(status: 200, body: '')

      proxy.destroy('1/../../api/v1/users/1')
      expect(stub).to have_been_requested
    end

    it 'escapes the id a record uses for its own writes' do
      record = ZammadAPI::Resources::Group.from_response(client.instance_variable_get(:@transport), { id: '1/../../api/v1/users/1' })
      stub = stub_request(:delete, "#{url}/1%2F..%2F..%2Fapi%2Fv1%2Fusers%2F1").to_return(status: 200, body: '')

      record.destroy
      expect(stub).to have_been_requested
    end

    it 'rejects an empty id rather than requesting the index' do
      expect { proxy.find('') }.to raise_error(ArgumentError, /record id is required/)
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end
  end

  describe '#create' do
    it 'posts the attributes' do
      stub = stub_request(:post, url)
        .with(query: { 'expand' => 'true' }, body: '{"name":"Support"}')
        .to_return(json_response({ id: 5, name: 'Support' }, status: 201))

      proxy.create(name: 'Support')
      expect(stub).to have_been_requested
    end

    it 'returns the persisted record' do
      stub_request(:post, url).with(query: hash_including({})).to_return(json_response({ id: 5, name: 'Support' }, status: 201))

      expect(proxy.create(name: 'Support')).to be_persisted
    end

    it 'raises ValidationError when Zammad rejects the attributes' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response({ error: 'Name is required' }, status: 422))

      expect { proxy.create({}) }.to raise_error(ZammadAPI::ValidationError, /Name is required/)
    end
  end

  describe '#find_by' do
    let(:search_url) { "#{url}/search" }

    it 'searches instead of filtering an index that cannot filter' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'Users'))
        .to_return(json_response([{ id: 1, name: 'Users' }]))

      proxy.find_by(name: 'Users')

      expect(stub).to have_been_requested
      expect(a_request(:get, url).with(query: hash_including({}))).not_to have_been_made
    end

    it 'returns the matching record' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([{ id: 1, name: 'Users' }]))

      expect(proxy.find_by(name: 'Users').id).to eq(1)
    end

    # Walking every page billed a request per page of hits to answer "no",
    # on the find_by(...) || create(...) path that runs for every new record.
    it 'costs one request when nothing matches, however many hits there are' do
      hits = Array.new(ZammadAPI::ResourceProxy::SEARCH_MAX_PER_PAGE) { { id: it + 1, name: 'Other' } }
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response(hits))

      expect(proxy.find_by(name: 'Users')).to be_nil
      expect(a_request(:get, search_url).with(query: hash_including({}))).to have_been_made.once
    end

    it 'asks for a single page of hits at the size the search endpoint serves' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('page' => '1', 'per_page' => ZammadAPI::ResourceProxy::SEARCH_MAX_PER_PAGE.to_s))
        .to_return(json_response([{ id: 1, name: 'Users' }]))

      proxy.find_by(name: 'Users')

      expect(stub).to have_been_requested
    end

    it 'returns a persisted record' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([{ id: 1, name: 'Users' }]))

      expect(proxy.find_by(name: 'Users')).to be_persisted
    end

    it 'skips a hit the search returned that does not actually match' do
      stub_request(:get, search_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users Archive' }, { id: 2, name: 'Users' }]))

      expect(proxy.find_by(name: 'Users').id).to eq(2)
    end

    it 'returns nil when the search matched nothing this record carries' do
      stub_request(:get, search_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users Archive' }]))

      expect(proxy.find_by(name: 'Users')).to be_nil
    end

    # Quoting a value that carries search syntax, to have it looked for rather
    # than obeyed, cost more than it bought: an instance searching without
    # Elasticsearch matches the term literally through a SQL LIKE, so the
    # quotes became characters the value had to contain, and a hyphen is
    # syntax - so `find_by(name: 'support-eu')` found nothing at all there.
    it 'sends a value carrying search syntax as it is' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'support-eu'))
        .to_return(json_response([]))

      proxy.find_by(name: 'support-eu')

      expect(stub).to have_been_requested
    end

    it 'sends a value that reads as a boolean query as it is' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'a AND b'))
        .to_return(json_response([]))

      proxy.find_by(name: 'a AND b')

      expect(stub).to have_been_requested
    end

    # Whatever the term meant to the backend, the answer is decided here.
    it 'still matches the record exactly' do
      stub_request(:get, search_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'a AND b' }]))

      expect(proxy.find_by(name: 'a AND b').id).to eq(1)
    end

    it 'returns nil when nothing matched' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([]))

      expect(proxy.find_by(name: 'Nope')).to be_nil
    end

    it 'matches on every attribute given, not just one' do
      stub_request(:get, search_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users', active: false }, { id: 2, name: 'Users', active: true }]))

      expect(proxy.find_by(name: 'Users', active: true).id).to eq(2)
    end

    # What a caller is promised: a record carrying both values comes back.
    # The spec here asserted the query string instead - that "Users Support"
    # went out - which a stub answers whatever it is handed, so nothing could
    # see that an instance without Elasticsearch matches that term through a
    # SQL LIKE per column and so finds neither of them.
    it 'finds a record by two string attributes' do
      stub_request(:get, search_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users', note: 'Other' }, { id: 2, name: 'Users', note: 'Support' }]))

      expect(proxy.find_by(name: 'Users', note: 'Support').id).to eq(2)
    end

    # The fence for the above: one value goes out, never the values joined.
    # Joined, the term is one no single column holds.
    it 'searches a single value rather than joining them' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'Support'))
        .to_return(json_response([]))

      proxy.find_by(name: 'Users', note: 'Support')
      expect(stub).to have_been_requested
    end

    it 'searches the longest value, as the most selective within the capped scan' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'a-very-specific-note'))
        .to_return(json_response([]))

      proxy.find_by(name: 'Users', note: 'a-very-specific-note')
      expect(stub).to have_been_requested
    end

    # A non-string went to the search engine as the word it prints as, so
    # `find_by(name: 'Users', active: true)` searched for "Users true" and
    # matched nothing.
    it 'keeps a non-string value out of the search term, and still matches on it' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'Users'))
        .to_return(json_response([{ id: 1, name: 'Users', active: false }, { id: 2, name: 'Users', active: true }]))

      expect(proxy.find_by(name: 'Users', active: true).id).to eq(2)
      expect(stub).to have_been_requested
    end

    it 'stops at the first match rather than walking the rest of the search' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([{ id: 1, name: 'Users' }]))

      proxy.find_by(name: 'Users')
      expect(a_request(:get, search_url).with(query: hash_including({}))).to have_been_made.once
    end

    it 'rejects a lookup with no attribute at all' do
      expect { proxy.find_by }.to raise_error(ArgumentError, /at least one attribute/)
    end

    # /api/v1/ticket_states/search is not routed, so the 404 arrived here as a
    # NotFoundError from a method documented to answer nil.
    it 'refuses a resource Zammad routes no search endpoint for' do
      expect { client.ticket_state.find_by(name: 'open') }
        .to raise_error(ZammadAPI::Error, /routes no search endpoint for ZammadAPI::Resources::TicketState/)
    end

    it 'points a refused lookup at walking the records' do
      expect { client.ticket_priority.find_by(name: '2 normal') }
        .to raise_error(ZammadAPI::Error, /all\.detect/)
    end

    it 'makes no request for a resource that cannot be searched' do
      expect { client.ticket_state.find_by(name: 'open') }.to raise_error(ZammadAPI::Error)
      expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/ticket_states/search").with(query: hash_including({})))
        .not_to have_been_made
    end

    it 'rejects a lookup with nothing to search for' do
      expect { proxy.find_by(name: '') }.to raise_error(ArgumentError, /nothing to search for/)
    end

    it 'rejects a lookup whose only value is not a string' do
      expect { proxy.find_by(active: true) }.to raise_error(ArgumentError, /nothing to search for in active: true/)
    end

    it 'says what a rejected lookup should pass instead' do
      expect { proxy.find_by(active: true) }.to raise_error(ArgumentError, /at least one string value to search on/)
    end

    it 'makes no request for a lookup with no string value' do
      expect { proxy.find_by(organization_id: 5) }.to raise_error(ArgumentError)
      expect(a_request(:get, search_url).with(query: hash_including({}))).not_to have_been_made
    end

    it 'rejects a lookup whose only string value is blank' do
      expect { proxy.find_by(name: '   ', active: true) }.to raise_error(ArgumentError, /nothing to search for/)
    end

    it 'makes no request for a lookup it rejects' do
      expect { proxy.find_by(name: nil) }.to raise_error(ArgumentError)
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end
  end

  describe '#find_by!' do
    let(:search_url) { "#{url}/search" }

    it 'returns the matching record' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([{ id: 1, name: 'Users' }]))

      expect(proxy.find_by!(name: 'Users').id).to eq(1)
    end

    it 'raises NotFoundError when nothing matched' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([]))

      expect { proxy.find_by!(name: 'Nope') }.to raise_error(ZammadAPI::NotFoundError)
    end

    it 'raises when the search answered with a record that does not match' do
      stub_request(:get, search_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users Archive' }]))

      expect { proxy.find_by!(name: 'Users') }.to raise_error(ZammadAPI::NotFoundError)
    end

    it 'names the query and the resource in the message' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([]))

      expect { proxy.find_by!(name: 'Nope', active: true) }
        .to raise_error("Can't find object by name and active (ZammadAPI::Resources::Group): no record matched")
    end

    it 'does not put the values it searched for in the message' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([]))

      expect { proxy.find_by!(name: 'secret-group') }
        .to raise_error(ZammadAPI::NotFoundError) { |error| expect(error.message).not_to include('secret-group') }
    end
  end

  describe '#exists?' do
    it 'is true when the record is there' do
      stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1 }))

      expect(proxy.exists?(1)).to be(true)
    end

    it 'is false for a 404' do
      stub_request(:get, "#{url}/404").with(query: hash_including({}))
        .to_return(json_response({ error: 'not found' }, status: 404))

      expect(proxy.exists?(404)).to be(false)
    end

    it 'does not swallow an authorization failure' do
      stub_request(:get, "#{url}/1").with(query: hash_including({}))
        .to_return(json_response({ error: 'no' }, status: 403))

      expect { proxy.exists?(1) }.to raise_error(ZammadAPI::AuthorizationError)
    end
  end

  describe '#destroy' do
    it 'deletes the record without fetching it first' do
      stub = stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')

      expect(proxy.destroy(1)).to be(true)
      expect(stub).to have_been_requested
      expect(a_request(:get, "#{url}/1")).not_to have_been_made
    end

    it 'raises NotFoundError for an unknown id' do
      stub_request(:delete, "#{url}/404").to_return(json_response({ error: 'not found' }, status: 404))

      expect { proxy.destroy(404) }.to raise_error(ZammadAPI::NotFoundError)
    end
  end

  # What a collection over this endpoint fetches per request when nothing asks
  # for another size: as many as the endpoint serves. Read off the resource
  # rather than written out, so that these stubs follow the declaration.
  def default_per_page = ZammadAPI::Resources::Group.page_limit

  describe '#all' do
    it 'returns a collection' do
      expect(proxy.all).to be_a(ZammadAPI::Collection)
    end

    it 'defaults to the collection page size' do
      stub = stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s })
        .to_return(json_response([]))

      proxy.all.to_a
      expect(stub).to have_been_requested
    end

    it 'takes no arguments' do
      expect { proxy.all(active: true) }.to raise_error(ArgumentError)
    end
  end

  describe '#where' do
    it 'returns a collection carrying the query parameters' do
      stub = stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s, 'sort_by' => 'name' })
        .to_return(json_response([]))

      proxy.where(sort_by: 'name').to_a
      expect(stub).to have_been_requested
    end

    it 'refuses an attribute filter the index endpoint would ignore' do
      expect { proxy.where(active: true) }
        .to raise_error(ArgumentError, %r{api/v1/groups ignores active})
    end

    it 'points at the call that can narrow by a value' do
      expect { proxy.where(active: true) }.to raise_error(ArgumentError, /use find_by for one record or search for many/)
    end

    it 'makes no request for a filter it rejects' do
      expect { proxy.where(active: true) }.to raise_error(ArgumentError)
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end

    context 'with an endpoint that does not even sort' do
      it 'says so, naming what it does honour' do
        expect { unit_client.ticket.where(sort_by: 'created_at') }
          .to raise_error(ArgumentError, /honours nothing beyond paging/)
      end
    end
  end

  describe 'enumerating a proxy directly' do
    def stub_page(page, records, per_page: default_per_page)
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
        .to_return(json_response(records))
    end

    # The walk confirms a short page with one more request, so a collection
    # that fits in a single page needs the empty page after it.
    def stub_last_page(page, records, per_page: default_per_page)
      stub_page(page, records, per_page: per_page)
      stub_page(page + 1, [], per_page: per_page)
    end

    it 'is Enumerable' do
      expect(proxy).to be_a(Enumerable)
    end

    it 'yields every record from #each' do
      stub_last_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(proxy.map(&:name)).to eq(%w[Users Support])
    end

    it 'walks pages, like the collection does' do
      stub_page(1, Array.new(default_per_page) { { id: it + 1 } })
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(proxy.map(&:id).size).to eq(default_per_page + 1)
    end

    # Forwarded to the collection rather than left to Enumerable#first, which
    # would take one record off the front of a page sized for walking.
    it 'reads one sized page for #first, without walking everything' do
      stub_page(1, [{ id: 1 }], per_page: 1)

      expect(proxy.first.id).to eq(1)
      expect(a_request(:get, url).with(query: hash_including({ 'page' => '2' }))).not_to have_been_made
    end

    it 'returns an Enumerator from #each without a block' do
      expect(proxy.each).to be_a(Enumerator)
    end

    it 'supports a lazy chain' do
      stub_page(1, [{ id: 1, active: true }, { id: 2, active: false }])

      expect(proxy.lazy.select(&:active).first(1).map(&:id)).to eq([1])
    end

    it 'forwards #page to the collection' do
      stub = stub_request(:get, url)
        .with(query: hash_including({ 'page' => '3' }))
        .to_return(json_response([]))

      proxy.page(3).to_a
      expect(stub).to have_been_requested
    end

    it 'forwards the page size #page was given' do
      stub = stub_page(1, [], per_page: 5)

      proxy.page(1, of: 5).to_a
      expect(stub).to have_been_requested
    end

    it 'forwards #find_each' do
      stub_last_page(1, [{ id: 1 }], per_page: 5)

      ids = []
      proxy.find_each(batch_size: 5) { ids << it.id }
      expect(ids).to eq([1])
    end

    it 'forwards #in_batches' do
      stub_last_page(1, [{ id: 1 }], per_page: 5)

      sizes = []
      proxy.in_batches(of: 5) { sizes << it.size }
      expect(sizes).to eq([1])
    end

    it 'forwards #pluck' do
      stub_last_page(1, [{ id: 1, name: 'Users' }])

      expect(proxy.pluck(:name)).to eq(['Users'])
    end

    it 'forwards #size' do
      stub_last_page(1, [{ id: 1 }])

      expect(proxy.size).to eq(1)
    end

    it 'forwards #length' do
      stub_last_page(1, [{ id: 1 }])

      expect(proxy.length).to eq(1)
    end

    it 'forwards #take, so it costs what #first costs' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)

      expect(proxy.take(2).map(&:id)).to eq([1, 2])
    end

    it 'forwards #first' do
      stub_page(1, [{ id: 1, name: 'Users' }], per_page: 1)

      expect(proxy.first.name).to eq('Users')
    end

    it 'forwards #empty?' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect(proxy).to be_empty
    end

    it 'keeps #find as a lookup by id rather than Enumerable#find' do
      stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, name: 'Users' }))

      expect(proxy.find(1).name).to eq('Users')
    end

    it 'leaves the block form to #detect' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(proxy.detect { it.name == 'Support' }.id).to eq(2)
    end

    it 'does not pretend to be an array, so it is not flattened away' do
      expect([proxy].flatten).to eq([proxy])
    end
  end

  describe 'narrowing a search' do
    it 'refuses to replace the search term' do
      expect { proxy.search('login failure').where(query: 'anything') }
        .to raise_error(ArgumentError, /cannot be passed to where/)
    end

    it 'still narrows a search by a parameter it does not own' do
      stub_request(:get, "#{url}/search")
        .with(query: hash_including({ 'query' => 'login failure', 'sort_by' => 'created_at', 'page' => '1' }))
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, "#{url}/search")
        .with(query: hash_including({ 'query' => 'login failure', 'sort_by' => 'created_at', 'page' => '2' }))
        .to_return(json_response([]))

      expect(proxy.search('login failure').where(sort_by: 'created_at').map(&:id)).to eq([1])
    end
  end

  describe '#search' do
    it 'refuses a resource Zammad routes no search endpoint for' do
      expect { client.ticket_state.search('open') }
        .to raise_error(ZammadAPI::Error, /routes no search endpoint for ZammadAPI::Resources::TicketState/)
    end

    it 'refuses a search of ticket articles, which Zammad indexes but does not route' do
      expect { client.ticket_article.search('hello') }
        .to raise_error(ZammadAPI::Error, /routes no search endpoint/)
    end

    it 'requests the search endpoint' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => ZammadAPI::ResourceProxy::SEARCH_MAX_PER_PAGE.to_s, 'query' => 'support' })
        .to_return(json_response([]))

      proxy.search('support').to_a
      expect(stub).to have_been_requested
    end

    it 'takes extra query parameters through where' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: hash_including('query' => 'support', 'sort_by' => 'name'))
        .to_return(json_response([]))

      proxy.search('support').where(sort_by: 'name').to_a
      expect(stub).to have_been_requested
    end

    it 'refuses a parameter the search endpoint would ignore' do
      expect { proxy.search('support').where(name: 'Users') }
        .to raise_error(ArgumentError, /Put the value in the search term instead/)
    end

    it 'requires a term' do
      expect { proxy.search }.to raise_error(ArgumentError)
    end

    it 'rejects an empty term' do
      expect { proxy.search('  ') }.to raise_error(ArgumentError, /non-empty query string/)
    end

    it 'rejects a term that is not a string' do
      expect { proxy.search(42) }.to raise_error(ArgumentError, /non-empty query string/)
    end
  end

  describe '#inspect' do
    it 'names the resource' do
      expect(proxy.inspect).to eq('#<ZammadAPI::ResourceProxy ZammadAPI::Resources::Group>')
    end
  end
end
