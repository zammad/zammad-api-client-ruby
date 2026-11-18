# frozen_string_literal: true

RSpec.describe ZammadAPI::Collection do
  subject(:collection) { client.groups.all }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  # What a collection over this endpoint fetches per request when nothing asks
  # for another size: as many as the endpoint serves. Read off the resource
  # rather than written out, so that these stubs follow the declaration.
  def default_per_page = ZammadAPI::Resources::Group.page_limit

  def stub_page(page, records, per_page: default_per_page)
    stub_request(:get, url)
      .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
      .to_return(json_response(records))
  end

  # The walk asks for another page only after a full one, so anything about
  # walking needs a page of the size that was requested.
  def full_page(first_id = 1)
    Array.new(default_per_page) { { id: first_id + it } }
  end

  # A short page cannot be told apart from one the server shrank, so the walk
  # confirms the end with one more request. Stubbing that empty page is what a
  # collection that fits in a single page looks like from out here.
  def stub_last_page(page, records, per_page: default_per_page)
    stub_page(page, records, per_page: per_page)
    stub_page(page + 1, [], per_page: per_page)
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

    it 'confirms the end of a short first page rather than assuming it' do
      stub_last_page(1, [{ id: 1 }])

      expect(collection.map(&:id)).to eq([1])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).to have_been_made
    end

    it 'stops on a page shorter than the one the endpoint has been serving' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.map(&:id)).to eq((1..(default_per_page + 1)).to_a)
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    it 'walks an endpoint that serves a smaller page than it was asked for' do
      stub_capped_endpoint(url, total: 120, max: 50)

      expect(collection.map(&:id)).to eq((1..120).to_a)
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
        .to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
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

    # The guard compares the decoded payload, not the bytes it arrived as.
    # Hashing raw_body is cheaper and looks equivalent - identical bytes do
    # mean identical records - but the implication that matters runs the other
    # way: an endpoint that ignores `page` and re-serializes the same records
    # with a different key order produces different bytes every time, so the
    # guard never fires. Every page is full, so neither the short-page break
    # nor the total break fires either, and the walk never ends.
    it 'raises PaginationError when a repeated page is re-serialized differently' do
      forwards  = Array.new(default_per_page) { { id: it, name: "a#{it}" } }
      backwards = forwards.map { { name: it[:name], id: it[:id] } }
      # Every page differs from the one before it in bytes and from none of
      # them in records, which a fixed sequence cannot express: WebMock repeats
      # its last response, so two pages running would come back byte-identical
      # and a byte digest would catch them one page later.
      order = [forwards, backwards].cycle
      stub_request(:get, url).with(query: hash_including({})).to_return { json_response(order.next) }

      # Bounded, because what this guards against is a walk that never ends
      # rather than one that ends wrongly - unbounded, a regression here hangs
      # the suite instead of failing it.
      expect { Timeout.timeout(5) { collection.to_a } }
        .to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
    end

    # A job that writes to the records it is handed changes what they
    # serialize as, so the page an endpoint repeats is never the same payload
    # twice. Compared by payload the guard never fired: every page was full,
    # and the job went round the same records for as long as it ran.
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

    # A search sorts by updated_at, so the write that changes a record's
    # payload moves it within the page as well.
    it 'raises PaginationError when a repeated page comes back changed and in another order' do
      round = 0
      stub_request(:get, url).with(query: hash_including({})).to_return do
        round += 1
        page = Array.new(default_per_page) { { id: it + 1, note: "round #{round}" } }
        json_response(round.odd? ? page : page.reverse)
      end

      expect { Timeout.timeout(5) { collection.to_a } }
        .to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
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
      stub_last_page(1, [{ id: 1 }])

      ids = []
      collection.find_each { ids << it.id }
      expect(ids).to eq([1])
    end

    it 'takes the page size inline' do
      stub_last_page(1, [{ id: 1 }], per_page: 50)

      expect(collection.find_each(batch_size: 50).map(&:id)).to eq([1])
    end

    it 'returns an Enumerator without a block' do
      expect(collection.find_each).to be_a(Enumerator)
    end

    it 'rejects a non-positive page size' do
      expect { collection.find_each(batch_size: 0) { nil } }
        .to raise_error(ArgumentError, 'batch_size needs a positive integer')
    end

    # Re-sizing the page silently changed which records the collection held:
    # page(3, per_page: 50) names records 101 to 150, and a batch_size of 10 turned
    # that into records 21 to 30 with nothing said about it.
    it 'refuses to re-size a collection already limited to a page' do
      expect { collection.page(3, per_page: 50).find_each(batch_size: 10) { nil } }
        .to raise_error(ArgumentError, /batch_size cannot be combined with page/)
    end

    it 'says how to name the page it would have served' do
      expect { collection.page(3, per_page: 50).find_each(batch_size: 10) { nil } }
        .to raise_error(ArgumentError, /page\(3, per_page: 10\)/)
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
      stub_last_page(1, [{ id: 1 }, { id: 2 }])

      batches = []
      collection.in_batches { batches << it.map(&:id) }
      expect(batches).to eq([[1, 2]])
    end

    # The batch is the block's own Array, and working it off with `shift` is
    # an ordinary way to consume one. The walk used to read the size of that
    # Array after the block returned, so a drained batch looked like an empty
    # page and ended the walk.
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

    it 'refuses to re-size a collection already limited to a page' do
      expect { collection.page(3, per_page: 50).in_batches(of: 10) { nil } }
        .to raise_error(ArgumentError, /of cannot be combined with page/)
    end

    it 'pulls one page per Enumerator#next' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)

      expect(collection.in_batches(of: 2).next.map(&:id)).to eq([1, 2])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end

    it 'rejects a non-positive page size' do
      expect { collection.in_batches(of: 0) { nil } }
        .to raise_error(ArgumentError, 'of needs a positive integer')
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
      stub_last_page(1, [{ id: 1 }])

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
      expect { collection.page(1, per_page: 0) }.to raise_error(ArgumentError, 'per_page needs a positive integer')
    end

    it 'rejects a non-integer page size' do
      expect { collection.page(1, per_page: '7') }.to raise_error(ArgumentError, 'per_page needs a positive integer')
    end
  end

  describe 'page size caps' do
    it 'clamps a walk to what a generic index endpoint serves' do
      stub_page(1, [], per_page: 1000)

      client.groups.all.find_each(batch_size: 5000).to_a
      expect(a_request(:get, url).with(query: hash_including('per_page' => '1000'))).to have_been_made
    end

    it 'refuses a page larger than a generic index endpoint serves' do
      expect { client.groups.all.page(1, per_page: 5000) }
        .to raise_error(ArgumentError, /serves at most 1000 records per page/)
    end

    it 'refuses a page larger than the ticket index endpoint serves' do
      expect { client.tickets.all.page(1, per_page: 5000) }
        .to raise_error(ArgumentError, /serves at most 100 records per page/)
    end

    it 'refuses a page larger than a search endpoint serves' do
      expect { client.users.search('smith').page(1, per_page: 5000) }
        .to raise_error(ArgumentError, /serves at most 200 records per page/)
    end

    it 'names the page that would have been served instead' do
      expect { client.tickets.all.page(3, per_page: 500) }
        .to raise_error(ArgumentError, /page\(3, per_page: 500\) would be sent as page 3 of 100/)
    end

    it 'names a page size the endpoint does serve' do
      expect { client.tickets.all.page(3, per_page: 500) }
        .to raise_error(ArgumentError, /Ask for page\(3, per_page: 100\) or fewer/)
    end

    it 'accepts a page exactly the size the endpoint serves' do
      expect(client.tickets.all.page(2, per_page: 100).inspect).to include('per_page=100')
    end

    it 'walks the whole list when asked for more per page than the endpoint serves' do
      stub_capped_endpoint("#{ClientHelper::BASE_URL}api/v1/tickets", total: 250, max: 100)

      expect(client.tickets.all.find_each(batch_size: 250).map(&:id)).to eq((1..250).to_a)
    end
  end

  it 'raises rather than building records out of a list of ids' do
    stub_page(1, [1, 2, 3])

    expect { collection.to_a }
      .to raise_error(ZammadAPI::ParseError, /expected a JSON array of objects, got an array holding Integer/)
  end

  # An index endpoint sorts and pages and does nothing else, so sorting has a
  # name of its own. It was reached through `where`, which refused nearly
  # everything else it was given.
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
      collection.order('active', 'name' => 'DESC').to_a
      expect(sorted_request('active,name', 'asc,desc')).to have_been_made
    end

    it 'sorts within an earlier order when chained' do
      collection.order(:active).order(name: :desc).to_a
      expect(sorted_request('active,name', 'asc,desc')).to have_been_made
    end

    it 'keeps the sort on every page it walks' do
      stub_request(:get, url).with(query: hash_including('page' => '1')).to_return(json_response(full_page))

      collection.order(:name).to_a
      expect(sorted_request('name', 'asc').with(query: hash_including('page' => '2'))).to have_been_made
    end

    it 'keeps the sort on an explicit page' do
      collection.order(:name).page(2, per_page: 10).to_a
      expect(sorted_request('name', 'asc').with(query: hash_including('page' => '2', 'per_page' => '10'))).to have_been_made
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

    it 'raises for an attribute named twice in one call' do
      expect { collection.order(:name, name: :desc) }.to raise_error(ArgumentError, /order was given name twice/)
    end

    it 'raises for an attribute the collection is already sorted by' do
      expect { collection.order(:name).order(name: :desc) }
        .to raise_error(ArgumentError, /order was given name, which this collection is already sorted by/)
    end

    it 'raises for a direction that is neither asc nor desc' do
      expect { collection.order(name: :down) }
        .to raise_error(ArgumentError, /order sorts name either :asc or :desc, got :down/)
    end

    # The spelling several other clients use. Read literally it sorts by an
    # attribute called desc, which Zammad answers with a server error.
    it 'raises for a direction written where an attribute belongs, and says how to write it' do
      expect { collection.order(:name, :desc) }
        .to raise_error(ArgumentError, /order reads :desc as an attribute to sort by.*order\(name: :desc\)/)
    end

    # Several attributes go out as one comma-separated parameter.
    it 'raises for a name that would be read as more than one attribute' do
      expect { collection.order('name,id') }
        .to raise_error(ArgumentError, /order needs the name of an attribute to sort by, got "name,id"/)
    end

    it 'raises for something that is not a name at all' do
      expect { collection.order(1) }.to raise_error(ArgumentError, /order needs the name of an attribute/)
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

      it 'points at a search, which does sort' do
        expect { client.tickets.all.order(:title) }.to raise_error(ArgumentError, /search\(term\)\.order\(\.\.\.\)/)
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
    end

    # Pointing at a search would send the caller in a circle where the
    # resource has none.
    it 'points at sort_by alone for an unsortable resource Zammad does not search' do
      unsortable = Class.new(ZammadAPI::Resources::Base) do
        path 'api/v1/things'
        sortable false
      end

      expect { ZammadAPI::ResourceProxy.new(unit_transport, unsortable).order(:name) }
        .to raise_error(ArgumentError, /ignores sort_by, so order would hand back the records as they were\. Sort what this collection yields instead/)
    end
  end

  describe '#pluck' do
    it 'returns one value per record for a single attribute' do
      stub_last_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(collection.pluck(:name)).to eq(%w[Users Support])
    end

    it 'returns one array per record for several attributes' do
      stub_last_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(collection.pluck(:id, :name)).to eq([[1, 'Users'], [2, 'Support']])
    end

    it 'accepts string keys' do
      stub_last_page(1, [{ id: 1, name: 'Users' }])

      expect(collection.pluck('name')).to eq(['Users'])
    end

    it 'yields nil for an attribute a record does not carry' do
      stub_last_page(1, [{ id: 1 }])

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

    # model_index_render reads sort_by, order_by and the paging and drops
    # every other parameter, so only_total_count means nothing to it, and
    # there is no header to read a total from either. Probing anyway spent a
    # request before the walk that had to happen regardless.
    it 'walks an index endpoint rather than probing it for a total it cannot give' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.count).to eq(default_per_page + 1)
      expect(a_request(:get, url).with(query: hash_including('only_total_count' => 'true'))).not_to have_been_made
    end

    # A count is the one answer nothing downstream can sanity check:
    # `Array.new(collection.count)` and `count.zero?` both take it at its word.
    it 'walks rather than reporting a total that cannot describe a result' do
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response({ total_count: -3 }))

      expect(client.users.search('smith').count).to eq(1)
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

    # Not an endpoint Zammad has - all four search actions route through
    # model_search_render, which reads only_total_count before it reads
    # anything else - but something other than the endpoint can answer: a
    # proxy error page, a login form, an HTML body with a 200 on it.
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
      stub_last_page(1, [{ id: 1 }, { id: 2 }, { id: 3 }])

      expect(collection.count { it.id > 1 }).to eq(2)
    end
  end

  describe '#size' do
    it 'walks the pages, like #count' do
      stub_last_page(1, [{ id: 1 }, { id: 2 }])

      expect(collection.size).to eq(2)
    end

    it 'asks a search endpoint for the total in one request' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/search")
        .with(query: { 'expand' => 'true', 'query' => 'smith', 'only_total_count' => 'true' })
        .to_return(json_response({ total_count: 4711 }))

      expect(client.users.search('smith').size).to eq(4711)
    end

    it 'is also spelled #length' do
      stub_last_page(1, [{ id: 1 }])

      expect(collection.length).to eq(1)
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

  # `take(n)` and `first(n)` ask one question. Enumerable answers both by
  # taking records off the front of a page sized for walking, so with #first
  # sizing its own page and this one left alone, what the same read cost
  # depended on which word was typed.
  describe '#take' do
    it 'reads a page sized for what was asked for' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)

      expect(collection.take(2).map(&:id)).to eq([1, 2])
    end

    it 'costs what the same read through #first costs' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 2)

      collection.take(2)
      expect(a_request(:get, url).with(query: hash_including('per_page' => '2'))).to have_been_made.once
    end

    it 'walks when more records are asked for than the endpoint serves' do
      stub_page(1, full_page)
      stub_page(2, [{ id: default_per_page + 1 }])

      expect(collection.take(default_per_page + 1).size).to eq(default_per_page + 1)
    end

    it 'leaves a zero count to Enumerable' do
      expect(collection.take(0)).to eq([])
    end

    # Enumerable#take always answers with an Array, where `first` reads a nil
    # as "just the one" and answers with a record.
    it 'refuses a nil the way Enumerable#take does' do
      expect { collection.take(nil) }.to raise_error(TypeError, /no implicit conversion/)
    end

    it 'reads on where the endpoint serves a smaller page than it was asked for' do
      stub_capped_endpoint(url, total: 5, max: 2)

      expect(collection.take(5).map(&:id)).to eq([1, 2, 3, 4, 5])
    end
  end

  # `find` on the proxy is the lookup by id, and Enumerable#find reads its
  # argument as an ifnone callable - so `all.find(1)` answered with an
  # Enumerator, made no request and raised nothing.
  describe '#find' do
    it 'is Enumerable#find with a block' do
      stub_last_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(collection.find { it.name == 'Support' }.id).to eq(2)
    end

    it 'refuses an id where a block belongs' do
      expect { collection.find(1) }
        .to raise_error(ArgumentError, /find on a ZammadAPI::Collection is Enumerable#find, which takes a block/)
    end

    it 'names the lookup that does take an id' do
      expect { collection.find(1) }.to raise_error(ArgumentError, /client\.groups\.find\(1\)/)
    end

    it 'names the resource the way a client does, for a multi-word one' do
      expect { client.ticket_articles.all.find(7) }
        .to raise_error(ArgumentError, /client\.ticket_articles\.find\(7\)/)
    end

    it 'points at detect for the block form' do
      expect { collection.find(1) }.to raise_error(ArgumentError, /detect \{ \.\.\. \}/)
    end

    it 'makes no request for the id it refuses' do
      expect { collection.find(1) }.to raise_error(ArgumentError)
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end

    it 'still returns an Enumerator without a block or an argument' do
      expect(collection.find).to be_a(Enumerator)
    end
  end

  # Enumerable#first takes its records off the front of a page this collection
  # sized for walking, so `all.first` downloaded a whole page to hand back one
  # record.
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
    # holds, so re-sizing it would move them - the same reason batch_size
    # cannot be combined with page.
    it 'leaves a collection already limited to a page at its own size' do
      stub_page(3, [{ id: 5 }, { id: 6 }], per_page: 2)

      expect(collection.page(3, per_page: 2).first.id).to eq(5)
    end

    it 'leaves a zero count to Enumerable' do
      expect(collection.first(0)).to eq([])
    end

    it 'makes no request for a zero count' do
      expect(collection.first(0)).to eq([])
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end

    # Sizing the request rather than limiting the collection to one page:
    # limited, this came back with whatever the first page held and nothing to
    # say the rest were there to be read.
    it 'reads on where the endpoint serves a smaller page than it was asked for' do
      stub_capped_endpoint(url, total: 5, max: 2)

      expect(collection.first(5).map(&:id)).to eq([1, 2, 3, 4, 5])
    end

    it 'stops as soon as it has what it asked for' do
      stub_capped_endpoint(url, total: 500, max: 2)

      expect(collection.first(3).map(&:id)).to eq([1, 2, 3])
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
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

  # A walk stops on what the endpoint served, and the size it serves is
  # learned from the first page rather than taken from `max_per_page`. Where
  # the server's cap is lower than the request - a cap the gem's declaration
  # has gone stale on - every page is short of what was asked for, and reading
  # the requested size would make each one look like the last.
  # A search names the ids for a page and then loads the records by id, so an
  # id whose record is gone by then leaves the page one short - on any page,
  # not only the last. An index page is a single query and has no such gap.
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

    # The bare array is what a Zammad before 6.5.1 answers with, and it says
    # nothing about how many hits there are. An empty page is then all there
    # is to end on, hits behind it or not: see the next group for an endpoint
    # that does say.
    it 'ends on the empty page where the endpoint reports no total' do
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

  # A page of a search can hold nothing with hits still behind it, for the
  # reason it can come back short: every id the search named for it has lost
  # its record. It takes one stale hit on the page of one that `first` and
  # `empty?` ask for, and a search serves the newest first. A Zammad from 6.5.1
  # on reports the size of the whole result beside the page where it is asked
  # to, which is what tells such a page from the end.
  describe 'a search that reports its total beside each page' do
    subject(:search) { client.users.search('smith') }

    let(:search_url) { "#{ClientHelper::BASE_URL}api/v1/users/search" }

    def stub_counted_page(page, ids, total:)
      stub_request(:get, search_url)
        .with(query: hash_including('page' => page.to_s))
        .to_return(json_response({ records: ids.map { { id: it } }, total_count: total }))
    end

    def walked_ids(per_page:) = search.find_each(batch_size: per_page).map(&:id)

    it 'asks for the total with every page of a walk' do
      stub_counted_page(1, [1], total: 2)
      stub_counted_page(2, [2], total: 2)
      stub_counted_page(3, [], total: 2)
      walked_ids(per_page: 1)

      expect(a_request(:get, search_url).with(query: hash_including('with_total_count' => 'true'))).to have_been_made.times(3)
    end

    it 'reads the records out of the object the total arrives in' do
      stub_counted_page(1, [1, 2, 3], total: 3)
      stub_counted_page(2, [], total: 3)

      expect(search.map(&:id)).to eq([1, 2, 3])
    end

    it 'reads on past an empty page the total says has hits behind it' do
      stub_counted_page(1, [1], total: 3)
      stub_counted_page(2, [], total: 3)
      stub_counted_page(3, [3], total: 3)
      stub_counted_page(4, [], total: 3)

      expect(walked_ids(per_page: 1)).to eq([1, 3])
    end

    # Two empty pages hold the same nothing, and the guard against a page
    # that repeats used to read that as an endpoint ignoring `page`.
    it 'reads on past two empty pages in a row' do
      stub_counted_page(1, [1], total: 4)
      stub_counted_page(2, [], total: 4)
      stub_counted_page(3, [], total: 4)
      stub_counted_page(4, [4], total: 4)
      stub_counted_page(5, [], total: 4)

      expect(walked_ids(per_page: 1)).to eq([1, 4])
    end

    it 'ends on an empty page once the pages read cover the total' do
      stub_counted_page(1, [1, 2], total: 4)
      last = stub_counted_page(2, [], total: 4)
      stub_counted_page(3, [5], total: 4)

      expect(walked_ids(per_page: 2)).to eq([1, 2])
      expect(last).to have_been_requested.once
      expect(a_request(:get, search_url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    # Elasticsearch stops counting at ten thousand hits and reports that as
    # the total. A walk ended on the figure would stop there.
    it 'does not end on the total while a page still holds records' do
      stub_counted_page(1, [1], total: 2)
      stub_counted_page(2, [2], total: 2)
      stub_counted_page(3, [3], total: 2)
      stub_counted_page(4, [], total: 2)

      expect(walked_ids(per_page: 1)).to eq([1, 2, 3])
    end

    it 'makes no more requests than the total has pages' do
      (1..5).each { stub_counted_page(it, [], total: 3) }

      expect(walked_ids(per_page: 1)).to eq([])
      expect(a_request(:get, search_url).with(query: hash_including({}))).to have_been_made.times(3)
    end

    it 'finds the first live hit behind a stale one' do
      stub_counted_page(1, [], total: 3)
      stub_counted_page(2, [2], total: 3)

      expect(search.first.id).to eq(2)
    end

    it 'is not empty where the first hit is stale and the next is live' do
      stub_counted_page(1, [], total: 3)
      stub_counted_page(2, [2], total: 3)

      expect(search.empty?).to be(false)
    end

    it 'is empty, in one request, where the stale hit was the only one' do
      stub_counted_page(1, [], total: 1)

      expect(search.empty?).to be(true)
      expect(a_request(:get, search_url).with(query: hash_including({}))).to have_been_made.once
    end

    it 'still raises PaginationError for a search that repeats a page of records' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response({ records: [{ id: 1 }], total_count: 9 }))

      expect { search.to_a }.to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
    end

    it 'ends on the empty page where the total is not a count' do
      stub_counted_page(1, [1], total: 'lots')
      stub_counted_page(2, [], total: -4)
      stub_counted_page(3, [3], total: 'lots')

      expect(walked_ids(per_page: 1)).to eq([1])
    end

    it 'raises ParseError for an object that is not a page of records' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response({ total_count: 3 }))

      expect { search.to_a }.to raise_error(ZammadAPI::ParseError, /expected a JSON array, got Hash/)
    end

    # The walk reads the id of every record on a page, so a null that got
    # past the shape check died there as NoMethodError rather than as the
    # ParseError a response of the wrong shape is.
    it 'raises ParseError for a null among the records' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response({ records: [nil, { id: 2 }], total_count: 2 }))

      expect { search.to_a }.to raise_error(ZammadAPI::ParseError, /an array holding NilClass/)
    end

    # One page is one request whatever it holds, so there is no walk for a
    # total to end, and the request is the one it always was.
    it 'does not ask a search limited to one page for the total' do
      stub_request(:get, search_url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))
      search.page(2).to_a

      expect(a_request(:get, search_url).with(query: { 'expand' => 'true', 'query' => 'smith', 'page' => '2', 'per_page' => '200' })).to have_been_made.once
    end

    # model_index_render drops the parameter with every other it does not
    # know, so asking would be noise on every request of every walk.
    it 'does not ask an index for the total' do
      index_url = "#{ClientHelper::BASE_URL}api/v1/users"
      stub_request(:get, index_url).with(query: hash_including({})).to_return(json_response([]))
      client.users.all.to_a

      expect(a_request(:get, index_url).with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => '1000' })).to have_been_made.once
    end
  end

  describe 'an endpoint that pages smaller than it was asked for' do
    it 'is walked to the end rather than truncated at the first short page' do
      stub_capped_endpoint(url, total: 5, max: 2)

      expect(collection.map(&:id)).to eq([1, 2, 3, 4, 5])
    end
  end
end
