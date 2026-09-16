# frozen_string_literal: true

RSpec.describe ZammadAPI::Collection do
  subject(:collection) { client.group.all }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }
  # `condition` is only honoured by a search endpoint, so the nested-filter
  # examples need one.
  let(:search_collection) { client.ticket.search('x') }

  def stub_page(page, records, per_page: ZammadAPI::Collection::DEFAULT_PER_PAGE)
    stub_request(:get, url)
      .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
      .to_return(json_response(records))
  end

  # The walk asks for another page only after a full one, so anything about
  # walking needs a page of the size that was requested.
  def full_page(first_id = 1)
    Array.new(ZammadAPI::Collection::DEFAULT_PER_PAGE) { { id: first_id + it } }
  end

  # A short page cannot be told apart from one the server shrank, so the walk
  # confirms the end with one more request. Stubbing that empty page is what a
  # collection that fits in a single page looks like from out here.
  def stub_last_page(page, records, per_page: ZammadAPI::Collection::DEFAULT_PER_PAGE)
    stub_page(page, records, per_page: per_page)
    stub_page(page + 1, [], per_page: per_page)
  end

  # An endpoint that reports the size of the whole result alongside the page,
  # the way Zammad's index endpoints do.
  def stub_counted_page(page, records, total:, per_page: ZammadAPI::Collection::DEFAULT_PER_PAGE)
    stub_request(:get, url)
      .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
      .to_return(json_response(records, headers: { 'X-Total-Count' => total.to_s }))
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

  # An endpoint that both caps the page below what was requested and reports a
  # total - the case where "short of what was asked for" and "short of what is
  # served" come apart.
  def stub_capped_counted_endpoint(records:, max:, total_header:)
    stub_request(:get, url).with(query: hash_including({})).to_return do |request|
      params = URI.decode_www_form(URI(request.uri).query).to_h
      limit  = [Integer(params['per_page']), max].min
      offset = (Integer(params['page']) - 1) * limit
      page   = Array(offset...[offset + limit, records].min).map { { id: it + 1 } }
      json_response(page, headers: { 'X-Total-Count' => total_header.to_s })
    end
  end

  it 'is an Enumerable' do
    expect(described_class.ancestors).to include(Enumerable)
  end

  describe '#each' do
    it 'walks every page until the server runs out of records' do
      stub_page(1, full_page)
      stub_page(2, [{ id: 101 }])

      expect(collection.map(&:id)).to eq((1..101).to_a)
    end

    it 'confirms the end of a short first page rather than assuming it' do
      stub_last_page(1, [{ id: 1 }])

      expect(collection.map(&:id)).to eq([1])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).to have_been_made
    end

    # Only where the endpoint says nothing about the size of the result. It
    # usually does, and the confirming request could then only ever come back
    # empty - a second request for every collection smaller than one page.
    it 'takes the endpoint at its word instead, when it reports a total' do
      stub_counted_page(1, [{ id: 1 }, { id: 2 }], total: 2)

      expect(collection.map(&:id)).to eq([1, 2])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end

    it 'keeps walking past a full page towards a reported total' do
      stub_counted_page(1, full_page, total: 101)
      stub_counted_page(2, [{ id: 101 }], total: 101)

      expect(collection.map(&:id)).to eq((1..101).to_a)
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    it 'falls back to confirming the end when the total is not a count' do
      stub_request(:get, url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }], headers: { 'X-Total-Count' => 'lots' }))
      stub_page(2, [])

      expect(collection.map(&:id)).to eq([1])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).to have_been_made
    end

    it 'stops on a page shorter than the one the endpoint has been serving' do
      stub_page(1, full_page)
      stub_page(2, [{ id: 101 }])

      expect(collection.map(&:id)).to eq((1..101).to_a)
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    it 'walks an endpoint that serves a smaller page than it was asked for' do
      stub_capped_endpoint(url, total: 120, max: 50)

      expect(collection.map(&:id)).to eq((1..120).to_a)
    end

    it 'stops on an empty page' do
      stub_page(1, full_page)
      stub_page(2, [])

      expect(collection.map(&:id)).to eq((1..100).to_a)
    end

    it 'yields persisted records' do
      stub_page(1, [{ id: 1 }])

      expect(collection.first).to be_persisted
    end

    it 'yields records of the right class' do
      stub_page(1, [{ id: 1 }])

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
      stub_page(1, full_page)

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
      stub_page(1, Array.new(ZammadAPI::Collection::DEFAULT_PER_PAGE) { { name: "a#{it}" } })
      stub_page(2, [{ name: 'b0' }])

      expect(collection.map(&:name)).to eq(Array.new(100) { "a#{it}" } + ['b0'])
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
      expect(seen).to eq(ZammadAPI::Collection::DEFAULT_PER_PAGE)
    end

    it 'refuses two spellings of one filter rather than dropping a value' do
      expect { collection.where('sort_by' => 'name', :sort_by => 'id') }
        .to raise_error(ArgumentError, /sort_by was given twice, as "sort_by" and as :sort_by/)
    end

    # `condition` is a Hash the search endpoints read. Transport refuses the
    # pair too, but not until the collection is enumerated, and every other
    # refusal `where` makes happens at the call that wrote it.
    it 'refuses a collision nested inside a structured filter' do
      expect { search_collection.where(condition: { 'state_id' => 1, :state_id => 2 }) }
        .to raise_error(ArgumentError, /parameter condition\[state_id\] was given twice/)
    end

    it 'still accepts a structured filter whose keys only look alike' do
      expect(search_collection.where(condition: { 'ticket.state_id' => { operator: 'is' } }))
        .to be_a(described_class)
    end

    it 'still accepts a filter given once by either spelling' do
      expect(collection.where('sort_by' => 'name')).to be_a(described_class)
      expect(collection.where(sort_by: 'name')).to be_a(described_class)
    end

    # The guard compares the decoded payload, not the bytes it arrived as.
    # Hashing raw_body is cheaper and looks equivalent - identical bytes do
    # mean identical records - but the implication that matters runs the other
    # way: an endpoint that ignores `page` and re-serializes the same records
    # with a different key order produces different bytes every time, so the
    # guard never fires. Every page is full, so neither the short-page break
    # nor the total break fires either, and the walk never ends.
    it 'raises PaginationError when a repeated page is re-serialized differently' do
      forwards  = Array.new(ZammadAPI::Collection::DEFAULT_PER_PAGE) { { id: it, name: "a#{it}" } }
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

    it 'raises PaginationError when records without an id repeat' do
      page = Array.new(ZammadAPI::Collection::DEFAULT_PER_PAGE) { { name: "a#{it}" } }
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
    # page(3, of: 50) names records 101 to 150, and a batch_size of 10 turned
    # that into records 21 to 30 with nothing said about it.
    it 'refuses to re-size a collection already limited to a page' do
      expect { collection.page(3, of: 50).find_each(batch_size: 10) { nil } }
        .to raise_error(ArgumentError, /batch_size cannot be combined with page/)
    end

    it 'says how to name the page it would have served' do
      expect { collection.page(3, of: 50).find_each(batch_size: 10) { nil } }
        .to raise_error(ArgumentError, /page\(3, of: 10\)/)
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

    it 'returns an Enumerator without a block' do
      expect(collection.in_batches).to be_a(Enumerator)
    end

    it 'refuses to re-size a collection already limited to a page' do
      expect { collection.page(3, of: 50).in_batches(of: 10) { nil } }
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

      expect(collection.page(2, of: 3).map(&:id)).to eq([3])
    end

    it 'keeps the size when the page moves' do
      stub_page(3, [{ id: 5 }], per_page: 3)

      expect(collection.page(2, of: 3).page(3).map(&:id)).to eq([5])
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
      expect { collection.page(1, of: 0) }.to raise_error(ArgumentError, 'of needs a positive integer')
    end

    it 'rejects a non-integer page size' do
      expect { collection.page(1, of: '7') }.to raise_error(ArgumentError, 'of needs a positive integer')
    end
  end

  describe 'page size caps' do
    it 'clamps a walk to what a generic index endpoint serves' do
      stub_page(1, [], per_page: 1000)

      client.group.all.find_each(batch_size: 5000).to_a
      expect(a_request(:get, url).with(query: hash_including('per_page' => '1000'))).to have_been_made
    end

    it 'refuses a page larger than a generic index endpoint serves' do
      expect { client.group.all.page(1, of: 5000) }
        .to raise_error(ArgumentError, /serves at most 1000 records per page/)
    end

    it 'refuses a page larger than the ticket index endpoint serves' do
      expect { client.ticket.all.page(1, of: 5000) }
        .to raise_error(ArgumentError, /serves at most 100 records per page/)
    end

    it 'refuses a page larger than a search endpoint serves' do
      expect { client.user.search('smith').page(1, of: 5000) }
        .to raise_error(ArgumentError, /serves at most 200 records per page/)
    end

    it 'names the page that would have been served instead' do
      expect { client.ticket.all.page(3, of: 500) }
        .to raise_error(ArgumentError, /page\(3, of: 500\) would be sent as page 3 of 100/)
    end

    it 'names a page size the endpoint does serve' do
      expect { client.ticket.all.page(3, of: 500) }
        .to raise_error(ArgumentError, /Ask for page\(3, of: 100\) or fewer/)
    end

    it 'accepts a page exactly the size the endpoint serves' do
      expect(client.ticket.all.page(2, of: 100).inspect).to include('per_page=100')
    end

    it 'walks the whole list when asked for more per page than the endpoint serves' do
      stub_capped_endpoint("#{ClientHelper::BASE_URL}api/v1/tickets", total: 250, max: 100)

      expect(client.ticket.all.find_each(batch_size: 250).map(&:id)).to eq((1..250).to_a)
    end
  end

  it 'raises rather than building records out of a list of ids' do
    stub_page(1, [1, 2, 3])

    expect { collection.to_a }
      .to raise_error(ZammadAPI::ParseError, /expected a JSON array of objects, got an array holding Integer/)
  end

  describe '#where' do
    it 'adds query parameters' do
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => '100', 'sort_by' => 'name' })
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '2', 'per_page' => '100', 'sort_by' => 'name' })
        .to_return(json_response([]))

      expect(collection.where(sort_by: 'name').map(&:id)).to eq([1])
    end

    it 'returns a new collection' do
      expect(collection.where(sort_by: 'name')).not_to be(collection)
    end

    it 'rejects an attribute filter the endpoint would drop' do
      expect { collection.where(name: 'Users') }
        .to raise_error(ArgumentError, /ignores name, so where would hand back unfiltered records/)
    end

    it 'names what the endpoint does honour' do
      expect { collection.where(name: 'Users') }.to raise_error(ArgumentError, /honours sort_by, order_by/)
    end

    it 'points at find_by and search for a resource Zammad searches' do
      expect { collection.where(name: 'Users') }
        .to raise_error(ArgumentError, /use find_by for one record or search for many/)
    end

    # Pointing at find_by would send the caller in a circle: find_by needs the
    # search endpoint this resource has none of.
    it 'points at detect for a resource Zammad does not search' do
      expect { client.ticket_state.all.where(name: 'open') }
        .to raise_error(ArgumentError, /routes none for this resource, so walk the records and pick with detect/)
    end

    # Both guards compare against Symbol lists, while `**params` collects a
    # String key just as happily.
    it 'accepts a string key for a parameter the endpoint honours' do
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => '100', 'sort_by' => 'name' })
        .to_return(json_response([]))

      collection.where('sort_by' => 'name').to_a
      expect(a_request(:get, url).with(query: hash_including('sort_by' => 'name'))).to have_been_made
    end

    it 'rejects a string key the endpoint would drop' do
      expect { collection.where('name' => 'Users') }
        .to raise_error(ArgumentError, /ignores name, so where would hand back unfiltered records/)
    end

    it 'does not name a string key as both ignored and honoured' do
      expect { collection.where('sort_by' => 'name') }.not_to raise_error
    end

    it 'rejects a string key for a parameter the collection owns' do
      expect { collection.where('page' => 2) }
        .to raise_error(ArgumentError, /page cannot be passed to where/)
    end

    %i[page per_page expand only_total_count].each do |reserved|
      it "rejects #{reserved}, which the collection controls itself" do
        expect { collection.where(reserved => 1) }.to raise_error(ArgumentError, /cannot be passed to where/)
      end
    end

    it 'rejects a search term rather than replacing the one search set' do
      expect { collection.where(query: 'anything') }.to raise_error(ArgumentError, /cannot be passed to where/)
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
      stub_page(2, [{ id: 101 }])

      expect(collection.pluck(:id)).to eq((1..101).to_a)
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

      expect(client.user.search('smith').count).to eq(4711)
    end

    it 'walks the pages when the endpoint cannot count' do
      stub_page(1, full_page)
      stub_page(2, [{ id: 101 }])

      expect(collection.count).to eq(101)
    end

    it 'walks the pages when a search endpoint reports no total' do
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response({}))
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))

      expect(client.user.search('smith').count).to eq(1)
    end

    it 'walks the pages when a search endpoint ignores only_total_count' do
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response([{ id: 1 }, { id: 2 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }, { id: 2 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))

      expect(client.user.search('smith').count).to eq(2)
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
      stub_page(1, full_page)
      stub_page(2, [{ id: 101 }])

      expect(collection.size).to eq(101)
    end

    it 'asks a search endpoint for the total in one request' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/search")
        .with(query: { 'expand' => 'true', 'query' => 'smith', 'only_total_count' => 'true' })
        .to_return(json_response({ total_count: 4711 }))

      expect(client.user.search('smith').size).to eq(4711)
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

      collection.page(2, of: 5).empty?
      expect(a_request(:get, url).with(query: hash_including('page' => '2', 'per_page' => '5'))).to have_been_made
    end
  end

  describe '#inspect' do
    it 'describes the collection without fetching it' do
      expect(collection.inspect)
        .to eq('#<ZammadAPI::Collection ZammadAPI::Resources::Group path="api/v1/groups" per_page=100>')
    end

    it 'mentions the page when limited to one' do
      expect(collection.page(4).inspect).to include('page=4')
    end
  end

  # The total is the one stop condition not derived from the records the
  # endpoint served, and it can be wrong: a count taken before permission
  # scoping, a stale cache, a proxy rewriting the header. Trusted on its own
  # it ended the walk early and handed back a truncated result with nothing
  # raised - and nothing to tell it apart from a complete one.
  describe 'a total the endpoint under-reports' do
    it 'does not truncate a walk that is still being served full pages' do
      stub_counted_page(1, full_page, total: 5)
      stub_page(2, [{ id: 200 }])
      stub_page(3, [])

      expect(collection.count).to eq(ZammadAPI::Collection::DEFAULT_PER_PAGE + 1)
    end

    it 'keeps walking when the endpoint has already served more than it counts' do
      stub_counted_page(1, full_page, total: 5)
      stub_page(2, [{ id: 200 }])
      stub_page(3, [])

      expect(collection.map(&:id).last).to eq(200)
    end

    # The header is still worth reading: an accurate total on a short page is
    # what saves the confirming request, which is why it is consulted at all.
    it 'still stops on one request when a short page matches the total' do
      stub_counted_page(1, [{ id: 1 }, { id: 2 }], total: 2)

      expect(collection.map(&:id)).to eq([1, 2])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end

    # Over-reporting costs nothing: the walk runs on and stops on the empty
    # page, which is what it did before there was a header to read.
    it 'stops on the records when the total over-reports' do
      stub_counted_page(1, [{ id: 1 }], total: 99)
      stub_page(2, [])

      expect(collection.map(&:id)).to eq([1])
    end

    # The page has to be short of what this endpoint serves, which is not the
    # same as short of what was asked for. Where the server's cap is lower
    # than the request, every page is short of the request, so reading the
    # requested size made each one look like the last: the walk ended at the
    # first page whose running count met an under-reporting total, four
    # records into five, with nothing raised.
    it 'does not truncate a walk on an endpoint that pages smaller than requested' do
      stub_capped_counted_endpoint(records: 5, max: 2, total_header: 4)

      expect(collection.map(&:id)).to eq([1, 2, 3, 4, 5])
    end
  end

  describe 'counting a search endpoint that ignores only_total_count' do
    let(:search_url) { "#{ClientHelper::BASE_URL}api/v1/users/search" }

    # The probe comes back as the usual page of records, and that page still
    # carries the size of the whole result. Thrown away, the probe was wasted
    # and count walked every page on top of it - 1 + N requests for an answer
    # that cost N.
    it 'reads the total from the header the ignored probe came back with' do
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response([{ id: 1 }, { id: 2 }], headers: { 'X-Total-Count' => '37' }))

      expect(client.user.search('smith').count).to eq(37)
      expect(a_request(:get, search_url).with(query: hash_including('page' => '1'))).not_to have_been_made
    end
  end
end
