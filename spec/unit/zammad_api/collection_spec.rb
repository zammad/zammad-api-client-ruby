# frozen_string_literal: true

RSpec.describe ZammadAPI::Collection do
  subject(:collection) { client.group.all(per_page: 2) }

  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  def stub_page(page, records, per_page: 2)
    stub_request(:get, url)
      .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
      .to_return(json_response(records))
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

    it 'stops on a page that is shorter than per_page' do
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
        .to raise_error(ZammadAPI::ParseError, %r{expected a JSON array from api/v1/groups, got Hash})
    end
  end

  describe '#each_page' do
    it 'yields one array per page' do
      stub_page(1, [{ id: 1 }, { id: 2 }])
      stub_page(2, [{ id: 3 }])

      pages = []
      collection.each_page { pages << it.map(&:id) }
      expect(pages).to eq([[1, 2], [3]])
    end

    it 'returns an Enumerator without a block' do
      expect(collection.each_page).to be_a(Enumerator)
    end
  end

  describe '#page' do
    it 'fetches only the requested page' do
      stub_page(2, [{ id: 3 }, { id: 4 }], per_page: 3)
      stub_request(:get, url).with(query: { 'expand' => 'true', 'page' => '2', 'per_page' => '3' })
        .to_return(json_response([{ id: 3 }, { id: 4 }, { id: 5 }]))

      expect(collection.page(2, per_page: 3).map(&:id)).to eq([3, 4, 5])
      expect(a_request(:get, url).with(query: hash_including('page' => '3'))).not_to have_been_made
    end

    it 'keeps the collection per_page when none is given' do
      stub_page(2, [{ id: 3 }, { id: 4 }])

      expect(collection.page(2).map(&:id)).to eq([3, 4])
    end

    it 'returns a new collection' do
      expect(collection.page(2)).not_to be(collection)
    end

    it 'leaves the original collection unpaged' do
      collection.page(2)
      expect(collection.current_page).to be_nil
    end

    it 'rejects page zero' do
      expect { collection.page(0) }.to raise_error(ArgumentError, /positive integer/)
    end

    it 'rejects a non-integer page' do
      expect { collection.page('2') }.to raise_error(ArgumentError, /positive integer/)
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
  end

  describe '#[]' do
    it 'fetches a single record by offset' do
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '3', 'per_page' => '1' })
        .to_return(json_response([{ id: 30 }]))

      expect(collection[2].id).to eq(30)
    end

    it 'returns nil past the end of the list' do
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '100', 'per_page' => '1' })
        .to_return(json_response([]))

      expect(collection[99]).to be_nil
    end

    it 'rejects a negative index' do
      expect { collection[-1] }.to raise_error(ArgumentError, /non-negative integer/)
    end
  end

  describe 'construction' do
    it 'rejects a non-positive per_page' do
      expect { client.group.all(per_page: 0) }.to raise_error(ArgumentError, /positive integer/)
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
