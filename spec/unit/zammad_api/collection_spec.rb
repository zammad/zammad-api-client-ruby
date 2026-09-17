# frozen_string_literal: true

RSpec.describe ZammadAPI::Collection do
  subject(:collection) { client.group.all }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }
  # `condition` is only honoured by a search endpoint, so the nested-filter
  # examples need one.
  let(:search_collection) { client.ticket.search('x') }

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
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s, 'sort_by' => 'name' })
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '2', 'per_page' => default_per_page.to_s, 'sort_by' => 'name' })
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
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s, 'sort_by' => 'name' })
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

      expect(client.user.search('smith').count).to eq(4711)
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

      expect(client.user.search('smith').count).to eq(1)
    end

    it 'walks the pages when a search endpoint answers with no total at all' do
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response({}))

      expect(client.user.search('smith').count).to eq(1)
    end

    it 'walks the pages when the total it answers with is not a count' do
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }]))
      stub_request(:get, search_url).with(query: hash_including('page' => '2'))
        .to_return(json_response([]))
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response({ total_count: 'lots' }))

      expect(client.user.search('smith').count).to eq(1)
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
      stub_last_page(1, [{ id: 1 }, { id: 2 }])

      expect(collection.size).to eq(2)
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
      expect { collection.find(1) }.to raise_error(ArgumentError, /client\.group\.find\(1\)/)
    end

    it 'names the resource the way a client does, for a multi-word one' do
      expect { client.ticket_article.all.find(7) }
        .to raise_error(ArgumentError, /client\.ticket_article\.find\(7\)/)
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

      expect(collection.page(3, of: 2).first.id).to eq(5)
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
  describe 'an endpoint that pages smaller than it was asked for' do
    it 'is walked to the end rather than truncated at the first short page' do
      stub_capped_endpoint(url, total: 5, max: 2)

      expect(collection.map(&:id)).to eq([1, 2, 3, 4, 5])
    end
  end
end
