# frozen_string_literal: true

RSpec.describe ZammadAPI::Collection do
  subject(:collection) { client.groups.all }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  # What a collection over this endpoint fetches per request when nothing asks
  # for another size: as many as the endpoint serves.
  def default_per_page = ZammadAPI::Resources::Group.page_limit

  def stub_page(page, records, per_page: default_per_page)
    stub_request(:get, url)
      .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
      .to_return(json_response(records))
  end

  # The walk asks for another page only after a full one.
  def full_page(first_id = 1)
    Array.new(default_per_page) { { id: first_id + it } }
  end

  describe '#each' do
    it 'walks every page until the server runs out of records' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.map(&:id)).to eq((1..(default_per_page + 1)).to_a)
    end

    it 'stops on a short first page without asking for the next' do
      stub_page(1, [{ id: 1 }])

      expect(collection.map(&:id)).to eq([1])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end

    it 'stops on an empty page' do
      stub_page(1, full_page)
      stub_page(2, [])

      expect(collection.map(&:id)).to eq((1..default_per_page).to_a)
    end

    it 'yields persisted records' do
      stub_page(1, [{ id: 1 }], per_page: 1)

      expect(collection.first).to be_persisted
    end

    it 'returns an Enumerator without a block' do
      expect(collection.each).to be_a(Enumerator)
    end

    it 'does not make a request until it is iterated' do
      collection
      expect(a_request(:get, url).with(query: hash_including({}))).not_to have_been_made
    end

    it 'works with lazy enumeration' do
      stub_page(1, [{ id: 1 }, { id: 2 }])

      expect(collection.lazy.map(&:id).first(2)).to eq([1, 2])
    end

    it 'raises ParseError when the endpoint does not return a list' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response({ id: 1 }))

      expect { collection.to_a }
        .to raise_error(ZammadAPI::ParseError, /expected a JSON array, got Hash/)
    end

    it 'raises PaginationError when the endpoint ignores the page parameter' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response(full_page))

      expect { collection.to_a }
        .to raise_error(ZammadAPI::PaginationError, /page 2 repeated page 1, so the endpoint is ignoring the page parameter/)
    end

    it 'does not hand the repeated page to the block before raising' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response(full_page))

      batches = []

      expect { collection.in_batches { batches << it } }.to raise_error(ZammadAPI::PaginationError)
      expect(batches.size).to eq(1)
    end

    # Pages are compared by the ids they hold, not by their payload.
    it 'raises PaginationError when a repeated page comes back with its records changed' do
      round = 0
      stub_request(:get, url).with(query: hash_including({})).to_return do
        round += 1
        json_response(Array.new(default_per_page) { { id: it + 1, updated_at: "2026-11-18T10:00:#{format('%02d', round)}Z" } })
      end

      batches = 0

      expect { Timeout.timeout(5) { collection.in_batches { batches += 1 } } }
        .to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
      expect(batches).to eq(1)
    end
  end

  describe '#find_each' do
    it 'yields every record' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)
      stub_page(2, [{ id: 3 }], per_page: 2)

      ids = []
      collection.find_each(batch_size: 2) { ids << it.id }
      expect(ids).to eq([1, 2, 3])
    end

    it 'walks at the default page size without one' do
      stub_page(1, [{ id: 1 }])

      ids = []
      collection.find_each { ids << it.id }
      expect(ids).to eq([1])
    end

    it 'takes the page size inline' do
      stub_page(1, [{ id: 1 }], per_page: 50)

      expect(collection.find_each(batch_size: 50).map(&:id)).to eq([1])
    end

    it 'returns an Enumerator without a block' do
      expect(collection.find_each).to be_a(Enumerator)
    end
  end

  describe '#in_batches' do
    it 'yields one array per page' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)
      stub_page(2, [{ id: 3 }], per_page: 2)

      batches = []
      collection.in_batches(of: 2) { batches << it.map(&:id) }
      expect(batches).to eq([[1, 2], [3]])
    end

    it 'yields a whole page at the default size without one' do
      stub_page(1, [{ id: 1 }, { id: 2 }])

      batches = []
      collection.in_batches { batches << it.map(&:id) }
      expect(batches).to eq([[1, 2]])
    end

    # The batch is the block's own Array, and working it off with `shift` is
    # an ordinary way to consume one.
    it 'keeps walking when the block empties the batch it was handed' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)
      stub_page(2, [{ id: 3 }], per_page: 2)

      ids = []
      collection.in_batches(of: 2) { |batch| ids << batch.shift.id until batch.empty? }
      expect(ids).to eq([1, 2, 3])
    end

    it 'returns an Enumerator without a block' do
      expect(collection.in_batches).to be_a(Enumerator)
    end

    it 'pulls one page per Enumerator#next' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)

      expect(collection.in_batches(of: 2).next.map(&:id)).to eq([1, 2])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end
  end

  describe '#page' do
    it 'fetches only the requested page' do
      stub_page(2, [{ id: 3 }, { id: 4 }])

      expect(collection.page(2).map(&:id)).to eq([3, 4])
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    it 'sizes the page, and so decides which records it holds' do
      stub_page(2, [{ id: 3 }], per_page: 3)

      expect(collection.page(2, per_page: 3).map(&:id)).to eq([3])
    end

    it 'keeps the size when the page moves' do
      stub_page(3, [{ id: 5 }], per_page: 3)

      expect(collection.page(2, per_page: 3).page(3).map(&:id)).to eq([5])
    end

    it 'returns a new collection and leaves the original unpaged' do
      stub_page(1, [{ id: 1 }])

      expect(collection.page(2)).not_to be(collection)
      expect(collection.map(&:id)).to eq([1])
    end
  end

  describe 'page size caps' do
    it 'clamps a walk to what a generic index endpoint serves' do
      stub_page(1, [], per_page: 1000)

      client.groups.all.find_each(batch_size: 5000).to_a
      expect(a_request(:get, url).with(query: hash_including('per_page' => '1000'))).to have_been_made
    end

    it 'clamps an explicit page to what the ticket index endpoint serves' do
      expect(client.tickets.all.page(3, per_page: 500).inspect).to include('page=3').and include('per_page=100')
    end

    it 'clamps an explicit page to what a search endpoint serves' do
      expect(client.users.search('smith').page(1, per_page: 5000).inspect).to include('per_page=200')
    end
  end

  describe '#order' do
    def sorted_request(sort_by, order_by)
      a_request(:get, url).with(query: hash_including('sort_by' => sort_by, 'order_by' => order_by))
    end

    before { stub_request(:get, url).with(query: hash_including({})).to_return(json_response([])) }

    it 'sorts ascending by an attribute named on its own' do
      collection.order(:name).to_a
      expect(sorted_request('name', 'asc')).to have_been_made
    end

    it 'sorts the way a keyword says' do
      collection.order(name: :desc).to_a
      expect(sorted_request('name', 'desc')).to have_been_made
    end

    # Zammad pairs the two lists by position and skips an attribute that has
    # no direction, so each attribute is sent with one.
    it 'sorts by several attributes, each with a direction' do
      collection.order(:active, name: :desc).to_a
      expect(sorted_request('active,name', 'asc,desc')).to have_been_made
    end

    it 'sorts within an earlier order when chained' do
      collection.order(:active).order(name: :desc).to_a
      expect(sorted_request('active,name', 'asc,desc')).to have_been_made
    end

    it 'turns an attribute an earlier order named the way the later one says' do
      collection.order(:name).order(name: :desc).to_a
      expect(sorted_request('name', 'desc')).to have_been_made
    end

    it 'leaves the collection it was called on unsorted' do
      collection.order(:name)
      collection.to_a

      expect(a_request(:get, url).with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s }))
        .to have_been_made
    end

    # TicketsController#index and UsersController#index hardcode the order and
    # drop sort_by with everything else they do not read.
    context 'with an index endpoint that is always served in id order' do
      it 'refuses, rather than handing back records it would be calling sorted' do
        expect { client.tickets.all.order(:title) }
          .to raise_error(ArgumentError, %r{api/v1/tickets is always served in the same order and ignores sort_by})
      end
    end

    context 'with a search' do
      let(:search_url) { "#{ClientHelper::BASE_URL}api/v1/tickets/search" }

      before { stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([])) }

      it 'sorts, though the index of the same resource does not' do
        client.tickets.search('printer').order(created_at: :desc).to_a

        expect(a_request(:get, search_url).with(query: hash_including('query' => 'printer', 'sort_by' => 'created_at', 'order_by' => 'desc')))
          .to have_been_made
      end
    end
  end

  describe '#pluck' do
    it 'returns one value per record for a single attribute' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(collection.pluck(:name)).to eq(%w[Users Support])
    end

    it 'returns one array per record for several attributes' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(collection.pluck(:id, :name)).to eq([[1, 'Users'], [2, 'Support']])
    end
  end

  describe '#count' do
    let(:search_url) { "#{ClientHelper::BASE_URL}api/v1/users/search" }

    it 'asks a search endpoint for the total in one request' do
      stub_request(:get, search_url)
        .with(query: { 'expand' => 'true', 'query' => 'smith', 'only_total_count' => 'true' })
        .to_return(json_response({ total_count: 4711 }))

      expect(client.users.search('smith').count).to eq(4711)
    end

    # An index drops only_total_count with every other parameter it does not
    # read, so there is no total to ask it for.
    it 'walks an index endpoint rather than asking it for a total' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.count).to eq(default_per_page + 1)
      expect(a_request(:get, url).with(query: hash_including('only_total_count' => 'true'))).not_to have_been_made
    end

    it 'walks the pages when the total it answers with is not a count' do
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response({ total_count: 'lots' }))

      expect(client.users.search('smith').count).to eq(1)
    end

    it 'walks the pages when something answers with records instead of a total' do
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }, { id: 2 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response([{ id: 1 }, { id: 2 }]))

      expect(client.users.search('smith').count).to eq(2)
    end

    it 'counts one page only when limited to a page' do
      stub_page(3, [{ id: 5 }, { id: 6 }])

      expect(collection.page(3).count).to eq(2)
    end

    it 'counts matches when given a block' do
      stub_page(1, [{ id: 1 }, { id: 2 }, { id: 3 }])

      expect(collection.count { it.id > 1 }).to eq(2)
    end
  end

  describe '#empty?' do
    it 'is false when the endpoint has a record' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      expect(collection).not_to be_empty
    end

    it 'is true when the endpoint has none' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect(collection).to be_empty
    end

    it 'asks for a single record rather than a whole page' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      collection.empty?
      expect(a_request(:get, url).with(query: hash_including('per_page' => '1'))).to have_been_made
    end
  end

  # `find` on the proxy is the lookup by id, so the collection refuses an id
  # rather than reading it as Enumerable#find's ifnone callable.
  describe '#find' do
    it 'is Enumerable#find with a block' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(collection.find { it.name == 'Support' }.id).to eq(2)
    end

    it 'refuses an id where a block belongs, and names the lookup that takes one' do
      expect { collection.find(1) }
        .to raise_error(ArgumentError, 'find on a collection takes a block; look a record up by id with client.<resource>.find(1)')
    end

    it 'still returns an Enumerator without a block or an argument' do
      expect(collection.find).to be_a(Enumerator)
    end
  end

  describe '#first' do
    it 'reads a page of one for a single record' do
      stub_page(1, [{ id: 1 }], per_page: 1)

      expect(collection.first.id).to eq(1)
    end

    it 'is nil when the endpoint has nothing' do
      stub_page(1, [], per_page: 1)

      expect(collection.first).to be_nil
    end

    it 'sizes the page to the number of records asked for' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)

      expect(collection.first(2).map(&:id)).to eq([1, 2])
    end

    # The page size of a collection limited to one says which records it
    # holds, so re-sizing it would move them.
    it 'leaves a collection already limited to a page at its own size' do
      stub_page(3, [{ id: 5 }, { id: 6 }], per_page: 2)

      expect(collection.page(3, per_page: 2).first.id).to eq(5)
    end
  end

  describe '#inspect' do
    it 'describes the collection without fetching it' do
      expect(collection.inspect)
        .to eq("#<ZammadAPI::Collection ZammadAPI::Resources::Group path=\"api/v1/groups\" per_page=#{default_per_page}>")
    end

    it 'mentions the page when limited to one' do
      expect(collection.page(4).inspect).to include('page=4')
    end
  end

  # A search names the ids for a page and then loads the records by id, so an
  # id whose record is gone by then leaves the page one short, on any page.
  # A search is therefore walked on to an empty page.
  describe 'a search, which can serve a page short before the last one' do
    subject(:search) { client.users.search('smith') }

    let(:search_url) { "#{ClientHelper::BASE_URL}api/v1/users/search" }
    let(:page_size)  { ZammadAPI::Collection::SEARCH_MAX_PER_PAGE }

    def stub_search_page(page, records)
      stub_request(:get, search_url)
        .with(query: hash_including('page' => page.to_s))
        .to_return(json_response(records))
    end

    def hits(range) = range.map { { id: it } }

    it 'walks on past a page that came back short' do
      stub_search_page(1, hits(1..page_size))
      stub_search_page(2, hits((page_size + 1)...(page_size * 2)))
      stub_search_page(3, hits([900, 901]))
      stub_search_page(4, [])

      expect(search.map(&:id)).to eq([*1...(page_size * 2), 900, 901])
    end

    it 'still reads only the one page a search was limited to' do
      stub_search_page(2, hits(1..3))

      expect(search.page(2).map(&:id)).to eq([1, 2, 3])
      expect(a_request(:get, search_url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end
  end
end
