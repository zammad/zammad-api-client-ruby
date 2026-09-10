# frozen_string_literal: true

RSpec.describe ZammadAPI::Collection do
  subject(:collection) { client.group.all.per(2) }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  def stub_page(page, records, per_page: 2)
    stub_request(:get, url)
      .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
      .to_return(json_response(records))
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
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [{ id: 3 }])

      expect(collection.map(&:id)).to eq([1, 2, 3])
    end

    it 'stops on a page that is shorter than the page size' do
      stub_page(1, [{ id: 1 }])

      expect(collection.map(&:id)).to eq([1])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end

    it 'stops on an empty page' do
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [])

      expect(collection.map(&:id)).to eq([1, 2])
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
      stub_page(1, [{ id: 1 }, { id: 2 }])

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
        .to_return(json_response([{ id: 1 }, { id: 2 }]))

      expect { collection.to_a }
        .to raise_error(ZammadAPI::PaginationError, /ignoring the page parameter/)
    end
  end

  describe '#find_each' do
    it 'yields every record' do
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [{ id: 3 }])

      ids = []
      collection.find_each { ids << it.id }
      expect(ids).to eq([1, 2, 3])
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
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [{ id: 3 }])

      batches = []
      collection.in_batches { batches << it.map(&:id) }
      expect(batches).to eq([[1, 2], [3]])
    end

    it 'takes the page size inline' do
      stub_page(1, [{ id: 1 }, { id: 2 }], per_page: 3)

      batches = []
      collection.in_batches(of: 3) { batches << it.map(&:id) }
      expect(batches).to eq([[1, 2]])
    end

    it 'returns an Enumerator without a block' do
      expect(collection.in_batches).to be_a(Enumerator)
    end

    it 'pulls one page per Enumerator#next' do
      stub_page(1, [{ id: 1 }, { id: 2 }])

      expect(collection.in_batches.next.map(&:id)).to eq([1, 2])
      expect(a_request(:get, url).with(query: hash_including('page' => '2'))).not_to have_been_made
    end
  end

  describe '#page' do
    it 'fetches only the requested page' do
      stub_page(2, [{ id: 3 }, { id: 4 }])

      expect(collection.page(2).map(&:id)).to eq([3, 4])
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    it 'combines with per in either order' do
      stub_page(2, [{ id: 3 }], per_page: 3)

      expect(collection.page(2).per(3).map(&:id)).to eq([3])
      expect(collection.per(3).page(2).map(&:id)).to eq([3])
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
  end

  describe '#per' do
    it 'sets the page size' do
      stub_page(1, [{ id: 1 }], per_page: 7)

      expect(collection.per(7).map(&:id)).to eq([1])
    end

    it 'returns a new collection' do
      expect(collection.per(7)).not_to be(collection)
    end

    it 'rejects a non-positive size' do
      expect { collection.per(0) }.to raise_error(ArgumentError, /positive integer/)
    end

    it 'rejects a non-integer size' do
      expect { collection.per('7') }.to raise_error(ArgumentError, /positive integer/)
    end
  end

  describe 'page size caps' do
    it 'clamps to what a generic index endpoint serves' do
      expect(client.group.all.per(5000).inspect).to include('per_page=1000')
    end

    it 'clamps to what the ticket index endpoint serves' do
      expect(client.ticket.all.per(5000).inspect).to include('per_page=100')
    end

    it 'clamps to what a search endpoint serves' do
      expect(client.user.search('smith').per(5000).inspect).to include('per_page=200')
    end

    it 'walks the whole list when asked for more per page than the endpoint serves' do
      stub_capped_endpoint("#{ClientHelper::BASE_URL}api/v1/tickets", total: 250, max: 100)

      expect(client.ticket.all.per(250).map(&:id)).to eq((1..250).to_a)
    end
  end

  describe '#where' do
    it 'adds query parameters' do
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => '2', 'active' => 'true' })
        .to_return(json_response([{ id: 1 }]))

      expect(collection.where(active: true).map(&:id)).to eq([1])
    end

    it 'returns a new collection' do
      expect(collection.where(active: true)).not_to be(collection)
    end

    it 'rejects parameters the collection controls itself' do
      expect { collection.where(page: 2) }.to raise_error(ArgumentError, /cannot be passed to where/)
      expect { collection.where(per_page: 2) }.to raise_error(ArgumentError, /cannot be passed to where/)
      expect { collection.where(expand: false) }.to raise_error(ArgumentError, /cannot be passed to where/)
    end
  end

  describe '#pluck' do
    it 'returns one value per record for a single attribute' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])
      stub_page(2, [])

      expect(collection.pluck(:name)).to eq(%w[Users Support])
    end

    it 'returns one array per record for several attributes' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])
      stub_page(2, [])

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
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [{ id: 3 }])

      expect(collection.pluck(:id)).to eq([1, 2, 3])
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
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [{ id: 3 }])

      expect(collection.count).to eq(3)
    end

    it 'walks the pages when a search endpoint reports no total' do
      stub_request(:get, search_url).with(query: hash_including('only_total_count' => 'true'))
        .to_return(json_response({}))
      stub_request(:get, search_url).with(query: hash_including('page' => '1'))
        .to_return(json_response([{ id: 1 }]))

      expect(client.user.search('smith').per(2).count).to eq(1)
    end

    it 'counts one page only when limited to a page' do
      stub_page(3, [{ id: 5 }, { id: 6 }])

      expect(collection.page(3).count).to eq(2)
    end

    it 'counts matches when given a block' do
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [{ id: 3 }])

      expect(collection.count { it.id > 1 }).to eq(2)
    end
  end

  describe '#inspect' do
    it 'describes the collection without fetching it' do
      expect(collection.inspect)
        .to eq('#<ZammadAPI::Collection ZammadAPI::Resources::Group path="api/v1/groups" per_page=2>')
    end

    it 'mentions the page when limited to one' do
      expect(collection.page(4).inspect).to include('page=4')
    end
  end
end
