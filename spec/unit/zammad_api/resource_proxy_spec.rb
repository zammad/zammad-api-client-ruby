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
    it 'asks for a single record rather than a whole page' do
      stub = stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => '1', 'name' => 'Users' })
        .to_return(json_response([{ id: 1, name: 'Users' }]))

      proxy.find_by(name: 'Users')
      expect(stub).to have_been_requested
    end

    it 'returns the matching record' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1, name: 'Users' }]))

      expect(proxy.find_by(name: 'Users').id).to eq(1)
    end

    it 'returns a persisted record' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      expect(proxy.find_by(name: 'Users')).to be_persisted
    end

    it 'returns nil when nothing matched' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect(proxy.find_by(name: 'Nope')).to be_nil
    end

    it 'costs a single request' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      proxy.find_by(name: 'Users')
      expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.once
    end
  end

  describe '#find_by!' do
    it 'returns the matching record' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      expect(proxy.find_by!(name: 'Users').id).to eq(1)
    end

    it 'raises NotFoundError when nothing matched' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect { proxy.find_by!(name: 'Nope') }.to raise_error(ZammadAPI::NotFoundError)
    end

    it 'names the query and the resource in the message' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect { proxy.find_by!(name: 'Nope', active: true) }
        .to raise_error("Can't find object by name and active (ZammadAPI::Resources::Group): no record matched")
    end

    it 'does not put the values it searched for in the message' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect { proxy.find_by!(name: 'secret-ish') }.to raise_error(/^(?!.*secret-ish)/)
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

  describe '#all' do
    it 'returns a collection' do
      expect(proxy.all).to be_a(ZammadAPI::Collection)
    end

    it 'defaults to the collection page size' do
      stub = stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => ZammadAPI::Collection::DEFAULT_PER_PAGE.to_s })
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
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => '100', 'active' => 'true' })
        .to_return(json_response([]))

      proxy.where(active: true).to_a
      expect(stub).to have_been_requested
    end
  end

  describe 'enumerating a proxy directly' do
    def stub_page(page, records, per_page: ZammadAPI::Collection::DEFAULT_PER_PAGE)
      stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => page.to_s, 'per_page' => per_page.to_s })
        .to_return(json_response(records))
    end

    it 'is Enumerable' do
      expect(proxy).to be_a(Enumerable)
    end

    it 'yields every record from #each' do
      stub_page(1, [{ id: 1, name: 'Users' }, { id: 2, name: 'Support' }])

      expect(proxy.map(&:name)).to eq(%w[Users Support])
    end

    it 'walks pages, like the collection does' do
      stub_page(1, Array.new(ZammadAPI::Collection::DEFAULT_PER_PAGE) { { id: it + 1 } })
      stub_page(2, [{ id: 101 }])

      expect(proxy.count).to eq(101)
    end

    it 'stops early for #first, without walking everything' do
      stub_page(1, [{ id: 1 }, { id: 2 }])

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

    it 'forwards #per to the collection' do
      stub = stub_page(1, [], per_page: 5)

      proxy.per(5).to_a
      expect(stub).to have_been_requested
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

    it 'forwards #size' do
      stub_page(1, [{ id: 1 }])

      expect(proxy.size).to eq(1)
    end

    it 'forwards #length' do
      stub_page(1, [{ id: 1 }])

      expect(proxy.length).to eq(1)
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

  describe '#search' do
    it 'requests the search endpoint' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => '100', 'query' => 'support' })
        .to_return(json_response([]))

      proxy.search('support').to_a
      expect(stub).to have_been_requested
    end

    it 'takes extra query parameters through where' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: hash_including('query' => 'support', 'limit' => '5'))
        .to_return(json_response([]))

      proxy.search('support').where(limit: 5).to_a
      expect(stub).to have_been_requested
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
