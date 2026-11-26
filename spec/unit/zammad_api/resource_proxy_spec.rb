# frozen_string_literal: true

RSpec.describe ZammadAPI::ResourceProxy do
  subject(:proxy) { client.groups }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  it 'exposes the resource class' do
    expect(proxy.resource_class).to eq(ZammadAPI::Resources::Group)
  end

  describe '#new' do
    it 'builds an unsaved record' do
      expect(proxy.new(name: 'Support')).to be_new_record
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

    context 'with an id' do
      it 'reads the record by its id, given as text' do
        stub_request(:get, "#{url}/5").with(query: { expand: 'true' }).to_return(json_response({ id: 5, name: 'Users' }))

        expect(proxy.find_by(id: '5').id).to eq(5)
        expect(a_request(:get, search_url).with(query: hash_including({}))).not_to have_been_made
      end

      it 'checks the other values against it' do
        stub_request(:get, "#{url}/5").with(query: { expand: 'true' }).to_return(json_response({ id: 5, name: 'Users' }))

        expect(proxy.find_by(id: 5, name: 'Other')).to be_nil
      end

      it 'answers nil for an id that names no record' do
        stub_request(:get, "#{url}/9").with(query: { expand: 'true' }).to_return(json_response({ error: 'not found' }, status: 404))

        expect(proxy.find_by(id: 9)).to be_nil
      end
    end

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

    # Zammad's search sorts by updated_at, newest first, not by relevance, so
    # the exact match can sit on any page of hits.
    context 'when more records match the term than one page holds' do
      let(:page_size) { ZammadAPI::Collection::SEARCH_MAX_PER_PAGE }
      let(:others)    { Array.new(page_size) { { id: it + 1, name: 'Users Archive' } } }

      def stub_page(number, records)
        stub_request(:get, search_url)
          .with(query: hash_including('page' => number.to_s))
          .to_return(json_response(records))
      end

      it 'finds a match on a later page' do
        stub_page(1, others)
        stub_page(2, [{ id: 999, name: 'Users' }])

        expect(proxy.find_by(name: 'Users').id).to eq(999)
      end
    end

    it 'skips a hit the search returned that does not actually match' do
      stub_request(:get, search_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users Archive' }, { id: 2, name: 'Users' }]))

      expect(proxy.find_by(name: 'Users').id).to eq(2)
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

    it 'searches the longest value, as the most selective of them' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'a-very-specific-note'))
        .to_return(json_response([]))

      proxy.find_by(name: 'Users', note: 'a-very-specific-note')
      expect(stub).to have_been_requested
    end

    it 'keeps a non-string value out of the search term, and still matches on it' do
      stub = stub_request(:get, search_url)
        .with(query: hash_including('query' => 'Users'))
        .to_return(json_response([{ id: 1, name: 'Users', active: false }, { id: 2, name: 'Users', active: true }]))

      expect(proxy.find_by(name: 'Users', active: true).id).to eq(2)
      expect(stub).to have_been_requested
    end

    it 'rejects a lookup with no attribute at all' do
      expect { proxy.find_by }.to raise_error(ArgumentError, /at least one attribute/)
    end

    context 'with a resource Zammad routes no search endpoint for' do
      let(:states_url) { "#{ClientHelper::BASE_URL}api/v1/ticket_states" }

      before do
        stub_request(:get, states_url).with(query: hash_including({}))
          .to_return(json_response([{ id: 1, name: 'new', state_type_id: 1 }, { id: 2, name: 'open', state_type_id: 2 }]))
      end

      it 'walks the records and answers with the one that matches' do
        expect(client.ticket_states.find_by(name: 'open').id).to eq(2)
      end
    end

    # Zammad matches words, so a value that is not a string would go out as
    # the word it prints as.
    context 'with no string value to search on' do
      before do
        stub_request(:get, url).with(query: hash_including({}))
          .to_return(json_response([{ id: 1, name: 'Users', active: false }, { id: 2, name: 'Support', active: true }]))
      end

      it 'walks the index and answers with the first record that matches' do
        expect(proxy.find_by(active: true).id).to eq(2)
      end

      it 'walks for a string value that is blank, which is nothing to search on either' do
        expect(proxy.find_by(name: '   ', active: true)).to be_nil
        expect(a_request(:get, search_url).with(query: hash_including({}))).not_to have_been_made
      end
    end

    it 'does not match nil against an attribute the record does not carry' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users' }]))

      expect(proxy.find_by(nmae: nil)).to be_nil
    end

    it 'does match nil against an attribute the record carries as nil' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users', note: nil }]))

      expect(proxy.find_by(note: nil).id).to eq(1)
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

    it 'names the query and the resource in the message' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([]))

      expect { proxy.find_by!(name: 'Nope', active: true) }
        .to raise_error("Can't find object by name and active (ZammadAPI::Resources::Group): no record matched")
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
  # for another size: as many as the endpoint serves.
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
  end

  describe '#order' do
    it 'returns a sorted collection of every record' do
      stub = stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s, 'sort_by' => 'name', 'order_by' => 'desc' })
        .to_return(json_response([]))

      proxy.order(name: :desc).to_a
      expect(stub).to have_been_requested
    end
  end

  describe 'enumerating a proxy directly' do
    def stub_page(page, records, per_page: default_per_page)
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
        .to_return(json_response(records))
    end

    it 'yields every record from #each' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(proxy.map(&:name)).to eq(%w[Users Support])
    end

    # Forwarded to the collection rather than left to Enumerable#first, which
    # would take one record off the front of a page sized for walking.
    it 'reads one sized page for #first, without walking everything' do
      stub_page(1, [{ id: 1 }], per_page: 1)

      expect(proxy.first.id).to eq(1)
      expect(a_request(:get, url).with(query: hash_including({ 'page' => '2' }))).not_to have_been_made
    end

    it 'forwards #page to the collection' do
      stub = stub_request(:get, url)
        .with(query: hash_including({ 'page' => '3' }))
        .to_return(json_response([]))

      proxy.page(3).to_a
      expect(stub).to have_been_requested
    end

    it 'forwards #find_each' do
      stub_page(1, [{ id: 1 }], per_page: 5)

      ids = []
      proxy.find_each(batch_size: 5) { ids << it.id }
      expect(ids).to eq([1])
    end

    it 'forwards #in_batches' do
      stub_page(1, [{ id: 1 }], per_page: 5)

      sizes = []
      proxy.in_batches(of: 5) { sizes << it.size }
      expect(sizes).to eq([1])
    end

    it 'forwards #pluck' do
      stub_page(1, [{ id: 1, name: 'Users' }])

      expect(proxy.pluck(:name)).to eq(['Users'])
    end

    it 'forwards #empty?' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect(proxy).to be_empty
    end
  end

  describe '#search' do
    it 'refuses a resource Zammad routes no search endpoint for' do
      expect { client.ticket_states.search('open') }
        .to raise_error(ZammadAPI::Error, /routes no search endpoint for ZammadAPI::Resources::TicketState/)
    end

    it 'requests the search endpoint' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => ZammadAPI::Collection::SEARCH_MAX_PER_PAGE.to_s, 'query' => 'support' })
        .to_return(json_response([]))

      proxy.search('support').to_a
      expect(stub).to have_been_requested
    end

    # Keywords go to the search endpoint as they are, for what it narrows by
    # besides the term.
    context 'with keywords' do
      let(:users_search) { "#{ClientHelper::BASE_URL}api/v1/users/search" }

      before { stub_request(:get, /search/).with(query: hash_including({})).to_return(json_response([])) }

      it 'sends ids' do
        client.users.search('x', ids: [1, 2]).to_a
        expect(a_request(:get, users_search).with(query: hash_including('query' => 'x', 'ids' => %w[1 2]))).to have_been_made
      end

      it 'sends a condition the way Rails reads a nested parameter back' do
        client.tickets.search('x', condition: { 'ticket.state_id' => { operator: 'is', value: [1] } }).to_a

        expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/tickets/search")
          .with(query: hash_including('condition' => { 'ticket.state_id' => { 'operator' => 'is', 'value' => ['1'] } })))
          .to have_been_made
      end
    end

    it 'rejects an empty term' do
      expect { proxy.search('  ') }.to raise_error(ArgumentError, /non-empty query string/)
    end

    it "says that '*' asks for every record" do
      expect { proxy.search('') }.to raise_error(ArgumentError, /Search for '\*' to ask for every record/)
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
