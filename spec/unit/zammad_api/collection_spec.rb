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

  # Mirrors Zammad's CanPaginate::Pagination: the endpoint reduces per_page to
  # its own maximum and pages by that reduced size.
  def stub_capped_endpoint(url, total:, max:)
    stub_request(:get, url).with(query: hash_including({})).to_return do |request|
      params = URI.decode_www_form(URI(request.uri).query).to_h
      limit  = [Integer(params['per_page']), max].min
      offset = (Integer(params['page']) - 1) * limit
      json_response(Array(offset...[offset + limit, total].min).map { { id: it + 1 } })
    end
  end

  it 'is an Enumerable' do
    expect(described_class.ancestors).to include(Enumerable)
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

    it 'stops on a page shorter than the one the endpoint has been serving' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.map(&:id)).to eq((1..(default_per_page + 1)).to_a)
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
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

    it 'yields records of the right class' do
      stub_page(1, [{ id: 1 }], per_page: 1)

      expect(collection.first).to be_a(ZammadAPI::Resources::Group)
    end

    it 'returns an Enumerator without a block' do
      expect(collection.each).to be_a(Enumerator)
    end

    it 'does not make a request until it is iterated' do
      collection
      expect(a_request(:get, url).with(query: hash_including({}))).not_to have_been_made
    end

    it 'stops fetching early when the caller stops consuming' do
      stub_page(1, [{ id: 1 }], per_page: 1)

      expect(collection.first).to be_a(ZammadAPI::Resources::Group)
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
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

    it 'keeps walking records that carry no id' do
      stub_page(1, Array.new(default_per_page) { { name: "a#{it}" } })
      stub_page(2, [{ name: 'b0' }])

      expect(collection.map(&:name)).to eq(Array.new(default_per_page) { "a#{it}" } + ['b0'])
    end

    it 'does not hand the repeated page to the block before raising' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response(full_page))

      batches = []

      expect { collection.in_batches { batches << it } }.to raise_error(ZammadAPI::PaginationError)
      expect(batches.size).to eq(1)
    end

    it 'does not yield the repeated records to each either' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response(full_page))

      seen = 0

      expect { collection.each { seen += 1 } }.to raise_error(ZammadAPI::PaginationError)
      expect(seen).to eq(default_per_page)
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

    it 'does not take two pages that share some of their records for a repeat' do
      stub_page(1, full_page)
      stub_page(2, full_page(2))
      stub_page(3, [])

      expect(collection.map(&:id)).to eq([*1..default_per_page, *2..(default_per_page + 1)])
    end

    it 'raises PaginationError when records without an id repeat' do
      page = Array.new(default_per_page) { { name: "a#{it}" } }
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response(page))

      expect { collection.to_a }
        .to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
    end

    # The block is the caller's: a StopIteration raised from it is not the
    # end of the walk.
    context 'when the block raises StopIteration' do
      let(:labels) { %w[x y].each }

      before { stub_page(1, [{ id: 1 }, { id: 2 }, { id: 3 }]) }

      it 'raises it, as the same block over an Array does' do
        expect { collection.map { |group| [group.id, labels.next] } }.to raise_error(StopIteration)
      end

      it 'raises it from each, rather than ending the walk as if it were complete' do
        seen = []
        expect { collection.each { |group| seen << [group.id, labels.next] } }.to raise_error(StopIteration)

        expect(seen).to eq([[1, 'x'], [2, 'y']])
      end

      it 'raises it from in_batches' do
        expect { collection.in_batches { raise StopIteration } }.to raise_error(StopIteration)
      end
    end

    it 'still ends a walk that a break leaves early' do
      stub_page(1, full_page)

      expect(collection.each { |group| break group.id if group.id == 2 }).to eq(2)
      expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.once
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

    it 'rejects a non-positive page size' do
      expect { collection.find_each(batch_size: 0) { nil } }
        .to raise_error(ArgumentError, 'per_page needs to be a positive integer')
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

    it 'does not take a batch the block shortened for a short page' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)
      stub_page(2, [{ id: 3 }, { id: 4 }], per_page: 2)
      stub_page(3, [], per_page: 2)

      ids = []
      collection.in_batches(of: 2) do |batch|
        ids.concat(batch.map(&:id))
        batch.pop if ids.size > 2
      end
      expect(ids).to eq([1, 2, 3, 4])
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).to have_been_made
    end

    it 'returns an Enumerator without a block' do
      expect(collection.in_batches).to be_a(Enumerator)
    end

    it 'pulls one page per Enumerator#next' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)

      expect(collection.in_batches(of: 2).next.map(&:id)).to eq([1, 2])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end

    it 'rejects a non-positive page size' do
      expect { collection.in_batches(of: 0) { nil } }
        .to raise_error(ArgumentError, 'per_page needs to be a positive integer')
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

    it 'rejects page zero' do
      expect { collection.page(0) }.to raise_error(ArgumentError, /positive integer/)
    end

    it 'rejects a non-integer page' do
      expect { collection.page('2') }.to raise_error(ArgumentError, /positive integer/)
    end

    it 'rejects a non-positive page size' do
      expect { collection.page(1, per_page: 0) }.to raise_error(ArgumentError, 'per_page needs to be a positive integer')
    end

    it 'rejects a non-integer page size' do
      expect { collection.page(1, per_page: '7') }.to raise_error(ArgumentError, 'per_page needs to be a positive integer')
    end
  end

  describe 'page size caps' do
    it 'clamps a walk to what a generic index endpoint serves' do
      stub_page(1, [], per_page: 1000)

      client.groups.all.find_each(batch_size: 5000).to_a
      expect(a_request(:get, url).with(query: hash_including('per_page' => '1000'))).to have_been_made
    end

    it 'clamps an explicit page to what a generic index endpoint serves' do
      stub_page(2, [], per_page: 1000)

      collection.page(2, per_page: 5000).to_a
      expect(a_request(:get, url).with(query: hash_including('page' => '2', 'per_page' => '1000'))).to have_been_made
    end

    it 'clamps an explicit page to what the ticket index endpoint serves' do
      expect(client.tickets.all.page(3, per_page: 500).inspect).to include('page=3').and include('per_page=100')
    end

    it 'clamps an explicit page to what a search endpoint serves' do
      expect(client.users.search('smith').page(1, per_page: 5000).inspect).to include('per_page=200')
    end

    it 'accepts a page exactly the size the endpoint serves' do
      expect(client.tickets.all.page(2, per_page: 100).inspect).to include('per_page=100')
    end

    it 'walks the whole list when asked for more per page than the endpoint serves' do
      stub_capped_endpoint("#{ClientHelper::BASE_URL}api/v1/tickets", total: 250, max: 100)

      expect(client.tickets.all.find_each(batch_size: 250).map(&:id)).to eq((1..250).to_a)
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

    it 'takes an attribute and a direction as strings' do
      collection.order('active', 'name' => 'desc').to_a
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

    it 'keeps the sort on every page it walks' do
      stub_request(:get, url).with(query: hash_including('page' => '1')).to_return(json_response(full_page))

      collection.order(:name).to_a
      expect(a_request(:get, url).with(query: hash_including('sort_by' => 'name', 'order_by' => 'asc', 'page' => '2'))).to have_been_made
    end

    it 'keeps the sort on an explicit page' do
      collection.order(:name).page(2, per_page: 10).to_a
      expect(sorted_request('name', 'asc').with(query: hash_including('page' => '2', 'per_page' => '10'))).to have_been_made
    end

    it 'sends no sort for a collection that asked for none' do
      collection.to_a
      expect(a_request(:get, url).with(query: hash_including({})) { !it.uri.query.match?(/sort_by|order_by/) }).to have_been_made
    end

    it 'returns a new collection' do
      expect(collection.order(:name)).not_to be(collection)
    end

    it 'leaves the collection it was called on unsorted' do
      collection.order(:name)
      collection.to_a

      expect(a_request(:get, url).with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s }))
        .to have_been_made
    end

    it 'makes no request until the collection is read' do
      collection.order(:name)
      expect(a_request(:get, url).with(query: hash_including({}))).not_to have_been_made
    end

    it 'raises without an attribute to sort by' do
      expect { collection.order }.to raise_error(ArgumentError, /order needs at least one attribute to sort by/)
    end

    # TicketsController#index and UsersController#index hardcode the order and
    # drop sort_by with everything else they do not read.
    context 'with an index endpoint that is always served in id order' do
      it 'refuses, rather than handing back records it would be calling sorted' do
        expect { client.tickets.all.order(:title) }
          .to raise_error(ArgumentError, %r{api/v1/tickets is always served in the same order and ignores sort_by})
      end

      it 'refuses for users too' do
        expect { client.users.all.order(:login) }.to raise_error(ArgumentError, %r{api/v1/users is always served})
      end

      it 'makes no request' do
        expect { client.tickets.all.order(:title) }.to raise_error(ArgumentError)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
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

      # What a search sorts by where it is not told differs by resource, so a
      # column named here would replace that order.
      it 'sends no sort for a search that asked for none' do
        client.tickets.search('printer').to_a

        expect(a_request(:get, search_url).with(query: hash_including({})) { !it.uri.query.match?(/sort_by|order_by/) }).to have_been_made
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

    it 'accepts string keys' do
      stub_page(1, [{ id: 1, name: 'Users' }])

      expect(collection.pluck('name')).to eq(['Users'])
    end

    it 'yields nil for an attribute a record does not carry' do
      stub_page(1, [{ id: 1 }])

      expect(collection.pluck(:name)).to eq([nil])
    end

    it 'walks every page, like each' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.pluck(:id)).to eq((1..(default_per_page + 1)).to_a)
    end

    it 'needs at least one attribute name' do
      expect { collection.pluck }.to raise_error(ArgumentError, 'pluck needs at least one attribute name')
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

    it 'walks the pages when a search endpoint answers with no total at all' do
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response({}))

      expect(client.users.search('smith').count).to eq(1)
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

    # Enumerable#each_slice asks for the size before it starts, and a size
    # would be a count, which is a walk of its own.
    it 'has no size, so each_slice reads the records once' do
      stub_page(1, [{ id: 1 }, { id: 2 }, { id: 3 }])

      expect(collection).not_to respond_to(:size)
      expect(collection.each_slice(2).map { it.map(&:id) }).to eq([[1, 2], [3]])
      expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.once
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

    it 'leaves the page size alone on a collection limited to one page' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 3 }]))

      collection.page(2, per_page: 5).empty?
      expect(a_request(:get, url).with(query: hash_including('page' => '2', 'per_page' => '5'))).to have_been_made
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

    it 'makes no request for the id it refuses' do
      expect { collection.find(1) }.to raise_error(ArgumentError)
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
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

    it 'walks instead when more records are asked for than the endpoint serves' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.first(default_per_page + 1).size).to eq(default_per_page + 1)
    end

    # The page size of a collection limited to one says which records it
    # holds, so re-sizing it would move them.
    it 'leaves a collection already limited to a page at its own size' do
      stub_page(3, [{ id: 5 }, { id: 6 }], per_page: 2)

      expect(collection.page(3, per_page: 2).first.id).to eq(5)
    end

    it 'makes no request for a zero count' do
      expect(collection.first(0)).to eq([])
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
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

  # ObjectManagerAttributesController#index renders every attribute in one
  # response and reads no parameter.
  describe 'an index that serves every record in one response' do
    subject(:collection) { client.resource(resource).all }

    let(:resource) do
      Class.new(ZammadAPI::Resources::Base) do
        def self.name = 'ObjectAttribute'

        path 'api/v1/object_manager_attributes'
        paginated false
      end
    end
    let(:url) { "#{ClientHelper::BASE_URL}api/v1/object_manager_attributes" }
    let(:records) { [{ id: 1, name: 'c' }, { id: 2, name: 'a' }, { id: 3, name: 'b' }] }

    # The same list whatever it is asked, which is what such an endpoint does.
    before { stub_request(:get, url).with(query: hash_including({})).to_return(json_response(records)) }

    it 'reads every record' do
      expect(collection.map(&:id)).to eq([1, 2, 3])
    end

    it 'spends one request on it' do
      collection.to_a
      expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.once
    end

    it 'names no page in that request' do
      collection.to_a
      expect(a_request(:get, url).with(query: { 'expand' => 'true' })).to have_been_made.once
    end

    context 'without the declaration, and a list as long as a page' do
      let(:resource) do
        Class.new(ZammadAPI::Resources::Base) do
          def self.name = 'ObjectAttribute'

          path 'api/v1/object_manager_attributes'
        end
      end
      let(:records) { full_page }

      it 'raises PaginationError, and says what to declare' do
        expect { collection.to_a }
          .to raise_error(ZammadAPI::PaginationError, /page 2 repeated page 1.*declare `paginated false` on the resource/)
      end
    end

    it 'hands the list over as one batch' do
      expect(collection.in_batches.map { |batch| batch.map(&:id) }).to eq([[1, 2, 3]])
    end

    it 'slices the list where a batch size is asked for' do
      expect(collection.in_batches(of: 2).map { |batch| batch.map(&:id) }).to eq([[1, 2], [3]])
    end

    it 'still spends one request where a batch size is asked for' do
      collection.find_each(batch_size: 1).to_a
      expect(a_request(:get, url).with(query: { 'expand' => 'true' })).to have_been_made.once
    end

    it 'yields no batch for a list with nothing on it' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect(collection.in_batches.to_a).to eq([])
    end

    it 'reads the first record off the one response' do
      expect(collection.first.id).to eq(1)
      expect(a_request(:get, url).with(query: { 'expand' => 'true' })).to have_been_made.once
    end

    it 'reads the first few' do
      expect(collection.first(2).map(&:id)).to eq([1, 2])
    end

    it 'counts the records' do
      expect(collection.count).to eq(3)
    end

    it 'says whether there are any' do
      expect(collection).not_to be_empty
    end

    it 'finds a record by what it carries' do
      expect(collection.detect { it.name == 'b' }.id).to eq(3)
    end

    # Every number would name the same records.
    it 'refuses a page' do
      expect { collection.page(2) }.to raise_error(ArgumentError, /serves every record in one response, so it has no pages/)
    end

    it 'still refuses a page that is not a number first' do
      expect { collection.page(0) }.to raise_error(ArgumentError, /positive integer/)
    end

    # Whether an index sorts is a declaration of its own.
    it 'sends a sort, and still no page' do
      collection.order(:name).to_a

      expect(a_request(:get, url).with(query: { 'expand' => 'true', 'sort_by' => 'name', 'order_by' => 'asc' })).to have_been_made.once
    end

    context 'when the resource says the endpoint does not sort either' do
      let(:resource) do
        Class.new(ZammadAPI::Resources::Base) do
          def self.name = 'ObjectAttribute'

          path 'api/v1/object_manager_attributes'
          paginated false
          sortable false
        end
      end

      it 'refuses a sort, which such an endpoint drops' do
        expect { collection.order(:name) }.to raise_error(ArgumentError, /ignores sort_by/)
      end
    end

    it 'says so in inspect' do
      expect(collection.inspect).to end_with('paginated=false>')
    end
  end

  describe ZammadAPI::PaginationError do
    it 'names the page that repeated and what to declare for an endpoint that does not page' do
      message = described_class.build(operation: 'get .all of object', page: 3).message

      expect(message).to include('page 3 repeated page 2').and include('declare `paginated false` on the resource')
    end
  end

  # A search names the ids for a page and then loads the records by id, so an
  # id whose record is gone by then leaves the page one short, on any page.
  # A search is therefore walked on to an empty page.
  describe 'a search, which can serve a page short before the last one' do
    subject(:search) { client.users.search('smith') }

    let(:search_url) { "#{ClientHelper::BASE_URL}api/v1/users/search" }
    let(:page_size)  { ZammadAPI::ResourceProxy::SEARCH_MAX_PER_PAGE }

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

    it 'walks on past a short first page too' do
      stub_search_page(1, hits(1...page_size))
      stub_search_page(2, hits(page_size..(page_size * 2)))
      stub_search_page(3, [])

      expect(search.map(&:id)).to eq((1..(page_size * 2)).to_a)
    end

    it 'ends on an empty page' do
      stub_search_page(1, hits(1..3))
      last = stub_search_page(2, [])
      stub_search_page(3, hits([4]))

      expect(search.map(&:id)).to eq([1, 2, 3])
      expect(last).to have_been_requested.once
      expect(a_request(:get, search_url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    it 'still raises PaginationError for a search that ignores the page parameter' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response(hits(1..3)))

      expect { search.to_a }.to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
    end

    it 'still reads only the one page a search was limited to' do
      stub_search_page(2, hits(1..3))

      expect(search.page(2).map(&:id)).to eq([1, 2, 3])
      expect(a_request(:get, search_url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end
  end
end
