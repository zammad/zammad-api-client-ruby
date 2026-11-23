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

    # A record where its id belongs went into the path as it inspects, and
    # the 404 for that path was read as an answer about the record.
    context 'with a record where its id belongs' do
      let(:record) { ZammadAPI::Resources::Group.from_response(client.instance_variable_get(:@transport), { id: 1, name: 'Users' }) }

      it 'refuses exists? rather than answering false for a record that exists' do
        expect { proxy.exists?(record) }.to raise_error(ArgumentError, /pass its id/)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'refuses find' do
        expect { proxy.find(record) }.to raise_error(ArgumentError, /pass its id/)
      end

      it 'refuses destroy rather than raising NotFoundError for a record that is there' do
        expect { proxy.destroy(record) }.to raise_error(ArgumentError, /pass its id/)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end
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

    # Zammad's search sorts by updated_at, newest first, not by relevance, so
    # the exact match can sit on any page of hits. Reading only the first one
    # answered nil for a record that exists, and find_by(...) || create(...)
    # then created its duplicate.
    context 'when more records match the term than one page holds' do
      let(:page_size) { ZammadAPI::ResourceProxy::SEARCH_MAX_PER_PAGE }
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

      it 'answers nil only once every page has been read' do
        stub_page(1, others)
        stub_page(2, others.map { it.merge(id: it[:id] + page_size) })
        last = stub_page(3, [])

        expect(proxy.find_by(name: 'Users')).to be_nil
        expect(last).to have_been_requested
      end

      it 'reads no further than the page the match is on' do
        stub_page(1, [*others.first(page_size - 1), { id: 999, name: 'Users' }])
        second = stub_page(2, [])

        proxy.find_by(name: 'Users')
        expect(second).not_to have_been_requested
      end
    end

    it 'asks for hits at the size the search endpoint serves' do
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
        .to_return(json_response([{ id: 1, name: 'Users Archive' }]), json_response([]))

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

    it 'searches the longest value, as the most selective of them' do
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

    # find_by used to raise here, which left it working on four resources out
    # of seven, and the caller writing all.detect by hand - the walk this makes.
    context 'with a resource Zammad routes no search endpoint for' do
      let(:states_url) { "#{ClientHelper::BASE_URL}api/v1/ticket_states" }

      before do
        stub_request(:get, states_url).with(query: hash_including('page' => '1'))
          .to_return(json_response([{ id: 1, name: 'new', state_type_id: 1 }, { id: 2, name: 'open', state_type_id: 2 }]))
        stub_request(:get, states_url).with(query: hash_including('page' => '2')).to_return(json_response([]))
      end

      it 'walks the records and answers with the one that matches' do
        expect(client.ticket_states.find_by(name: 'open').id).to eq(2)
      end

      it 'answers nil when none does' do
        expect(client.ticket_states.find_by(name: 'closed')).to be_nil
      end

      it 'never asks the search endpoint, which would answer 404' do
        client.ticket_states.find_by(name: 'open')
        expect(a_request(:get, "#{states_url}/search").with(query: hash_including({}))).not_to have_been_made
      end

      it 'stops at the page the match is on' do
        client.ticket_states.find_by(name: 'new')
        expect(a_request(:get, states_url).with(query: hash_including('page' => '2'))).not_to have_been_made
      end

      it 'matches on a value of any type' do
        expect(client.ticket_states.find_by(state_type_id: 2).name).to eq('open')
      end
    end

    # A value that is not a string cannot be searched on - Zammad matches
    # words, so it would go out as the word it prints as - and this used to
    # raise for want of one.
    context 'with no string value to search on' do
      before do
        stub_request(:get, url).with(query: hash_including('page' => '1'))
          .to_return(json_response([{ id: 1, name: 'Users', active: false }, { id: 2, name: 'Support', active: true }]))
        stub_request(:get, url).with(query: hash_including('page' => '2')).to_return(json_response([]))
      end

      it 'walks the index and answers with the first record that matches' do
        expect(proxy.find_by(active: true).id).to eq(2)
      end

      it 'does not search for the word the value prints as' do
        proxy.find_by(active: true)
        expect(a_request(:get, search_url).with(query: hash_including({}))).not_to have_been_made
      end

      it 'answers nil once the whole index has been read' do
        expect(proxy.find_by(active: nil)).to be_nil
        expect(a_request(:get, url).with(query: hash_including('page' => '2'))).to have_been_made
      end

      it 'walks for a string value that is blank, which is nothing to search on either' do
        expect(proxy.find_by(name: '   ', active: true)).to be_nil
        expect(a_request(:get, search_url).with(query: hash_including({}))).not_to have_been_made
      end
    end

    # record[key] is nil for an attribute a record does not carry, so a nil
    # value matched every record a misspelled name was asked of.
    it 'does not match nil against an attribute the record does not carry' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users' }]), json_response([]))

      expect(proxy.find_by(nmae: nil)).to be_nil
    end

    it 'does match nil against an attribute the record carries as nil' do
      stub_request(:get, url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, name: 'Users', note: nil }]), json_response([]))

      expect(proxy.find_by(note: nil).id).to eq(1)
    end
  end

  # An id is what addresses a record, and the one value a search for it or
  # a walk to it is the wrong way to find: given as an Integer the index was
  # walked until the record came by, and given as the String a request
  # parameter is, no hit ever carried it.
  describe '#find_by with an id' do
    let(:member_url) { "#{url}/5" }

    def stub_member(body = { id: 5, name: 'Users', active: true })
      stub_request(:get, member_url).with(query: hash_including({})).to_return(json_response(body))
    end

    def requests_made = a_request(:get, /#{Regexp.escape(url)}/)

    it 'reads the record by its id, in one request' do
      stub_member

      expect(proxy.find_by(id: 5).name).to eq('Users')
      expect(requests_made).to have_been_made.once
    end

    it 'reads it expanded, as a search and an index serve it' do
      stub = stub_request(:get, member_url).with(query: { 'expand' => 'true' }).to_return(json_response({ id: 5 }))

      proxy.find_by(id: 5)
      expect(stub).to have_been_requested
    end

    it 'finds the record by the String a request parameter is' do
      stub_member

      expect(proxy.find_by(id: '5').id).to eq(5)
    end

    it 'takes the id under a String key' do
      stub_member

      expect(proxy.find_by('id' => 5).id).to eq(5)
    end

    it 'answers nil where Zammad has no such record' do
      stub_request(:get, member_url).with(query: hash_including({})).to_return(json_response({ error: 'not found' }, status: 404))

      expect(proxy.find_by(id: 5)).to be_nil
    end

    it 'raises from find_by! where Zammad has no such record' do
      stub_request(:get, member_url).with(query: hash_including({})).to_return(json_response({ error: 'not found' }, status: 404))

      expect { proxy.find_by!(id: 5) }.to raise_error(ZammadAPI::NotFoundError, /find object by id/)
    end

    it 'answers with the record where it carries the other values too' do
      stub_member

      expect(proxy.find_by(id: 5, name: 'Users', active: true).id).to eq(5)
    end

    it 'answers nil where it does not carry one of them' do
      stub_member

      expect(proxy.find_by(id: 5, name: 'Support')).to be_nil
    end

    it 'answers nil where it lacks an attribute that was asked for' do
      stub_member

      expect(proxy.find_by(id: 5, note: nil)).to be_nil
    end

    it 'leaves any other failure to say what it is' do
      stub_request(:get, member_url).with(query: hash_including({})).to_return(json_response({ error: 'Not authorized' }, status: 403))

      expect { proxy.find_by(id: 5) }.to raise_error(ZammadAPI::AuthorizationError)
    end

    # Zammad answers `organizations/5` with `{}` for a customer who belongs
    # to no organization, whichever organization 5 is.
    it 'answers nil for an object that carries no id' do
      stub_member({})

      expect(proxy.find_by(id: 5)).to be_nil
    end

    it 'reads a String of digits as the number it writes' do
      stub_member

      expect(proxy.find_by(id: '05').id).to eq(5)
    end

    [nil, '', 'me', '5abc', ' 5', :me, 5.0, [5], '5'.encode('UTF-16LE'), "5\xff"].each do |value|
      it "answers nil for #{value.inspect}, the id of no record, without a request" do
        expect(proxy.find_by(id: value)).to be_nil
        expect(requests_made).not_to have_been_made
      end
    end

    it 'does the same for a resource with no search endpoint' do
      states_url = "#{ClientHelper::BASE_URL}api/v1/ticket_states"
      stub_request(:get, "#{states_url}/2").with(query: hash_including({})).to_return(json_response({ id: 2, name: 'open' }))

      expect(unit_client.ticket_states.find_by(id: 2, name: 'open').id).to eq(2)
      expect(a_request(:get, states_url).with(query: hash_including({}))).not_to have_been_made
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
        .to_return(json_response([{ id: 1, name: 'Users Archive' }]), json_response([]))

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

  # An index that serves its whole list and reads no page was walked into the
  # guard against an endpoint that ignores `page`, so a lookup that missed on
  # the first page raised instead of answering nil.
  describe 'a resource whose index does not page' do
    subject(:proxy) { client.resource(resource) }

    let(:resource) do
      Class.new(ZammadAPI::Resources::Base) do
        def self.name = 'ObjectAttribute'

        path 'api/v1/object_manager_attributes'
        paginated false
      end
    end
    let(:url) { "#{ClientHelper::BASE_URL}api/v1/object_manager_attributes" }

    before do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1, name: 'a' }, { id: 2, name: 'b' }]))
    end

    it 'finds a record by an attribute' do
      expect(proxy.find_by(name: 'b').id).to eq(2)
    end

    it 'answers nil for a lookup that matches nothing' do
      expect(proxy.find_by(name: 'missing')).to be_nil
    end

    it 'spends one request on a miss' do
      proxy.find_by(name: 'missing')
      expect(a_request(:get, url).with(query: { 'expand' => 'true' })).to have_been_made.once
    end

    it 'lets a miss go on to create the record' do
      created = stub_request(:post, url).with(query: hash_including({})).to_return(json_response({ id: 3, name: 'missing' }, status: 201))

      expect((proxy.find_by(name: 'missing') || proxy.create(name: 'missing')).id).to eq(3)
      expect(created).to have_been_requested
    end

    it 'reads every record straight off the proxy' do
      expect(proxy.map(&:name)).to eq(%w[a b])
    end

    # The declaration is about the index. A search endpoint always pages.
    it 'still pages a search' do
      resource.searchable true
      search = stub_request(:get, "#{url}/search")
        .with(query: hash_including('page' => '1', 'per_page' => described_class::SEARCH_MAX_PER_PAGE.to_s))
        .to_return(json_response({ records: [], total_count: 0 }))

      proxy.search('a').to_a
      expect(search).to have_been_requested
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

    # What Zammad answers a customer who belongs to no organization with,
    # for any organization id: 200 and an object with nothing in it.
    it 'is false where Zammad answers with an object that names no record' do
      stub_request(:get, "#{url}/5").with(query: hash_including({})).to_return(json_response({}))

      expect(proxy.exists?(5)).to be(false)
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

    it 'answers true for the empty object Zammad answers a DELETE with' do
      stub_request(:delete, "#{url}/1").to_return(json_response({}))

      expect(proxy.destroy(1)).to be(true)
    end

    # The page of something in front of Zammad that never passed the DELETE
    # on. This answered true for it, with the record still in Zammad.
    it 'raises ParseError for a 2xx whose body is not JSON' do
      stub_request(:delete, "#{url}/1").to_return(status: 200, body: '<html>Please sign in</html>', headers: { 'Content-Type' => 'text/html' })

      expect { proxy.destroy(1) }
        .to raise_error(ZammadAPI::ParseError, "Can't destroy object (ZammadAPI::Resources::Group): expected a JSON body or none, got text/html")
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

  describe '#order' do
    it 'returns a sorted collection of every record' do
      stub = stub_request(:get, url)
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => default_per_page.to_s, 'sort_by' => 'name,id', 'order_by' => 'desc,asc' })
        .to_return(json_response([]))

      proxy.order(name: :desc).to_a
      expect(stub).to have_been_requested
    end

    it 'is the order of the collection all hands back' do
      expect(proxy.order(:name).inspect).to eq(proxy.all.order(:name).inspect)
    end

    it 'refuses a resource whose index endpoint does not sort' do
      expect { unit_client.tickets.order(:created_at) }
        .to raise_error(ArgumentError, %r{api/v1/tickets is always served in the same order})
    end

    # where took a sort and refused nearly everything else, which is why it
    # went: the name promised a filter an index endpoint does not have.
    it 'has no where to reach for instead' do
      expect(proxy).not_to respond_to(:where)
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

      proxy.page(1, per_page: 5).to_a
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

    # A proxy is Enumerable, and Enumerable's own two ask for the size before
    # they start, which is a walk of its own.
    it 'forwards #each_slice, which walks the pages once' do
      stub_last_page(1, [{ id: 1 }, { id: 2 }, { id: 3 }])

      groups = []
      proxy.each_slice(2) { groups << it.map(&:id) }
      expect(groups).to eq([[1, 2], [3]])
      expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.twice
    end

    it 'forwards #each_cons, which walks the pages once' do
      stub_last_page(1, [{ id: 1 }, { id: 2 }, { id: 3 }])

      runs = []
      proxy.each_cons(2) { runs << it.map(&:id) }
      expect(runs).to eq([[1, 2], [2, 3]])
      expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.twice
    end

    it 'forwards #lazy, which slices without counting first' do
      stub_last_page(1, [{ id: 1 }, { id: 2 }, { id: 3 }])

      expect(proxy.lazy.each_slice(2).first(1).map { it.map(&:id) }).to eq([[1, 2]])
      expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.once
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

    # A proxy is Enumerable, so it had Enumerable's own, which read a page
    # sized for walking to answer what one record answers.
    it 'forwards #any? and #none?, which ask for a single record' do
      stub_page(1, [{ id: 1, name: 'Users' }], per_page: 1)

      expect(proxy.any?).to be(true)
      expect(proxy.none?).to be(false)
      expect(a_request(:get, url).with(query: hash_including('per_page' => '1'))).to have_been_made.twice
    end

    it 'forwards the block of #any? as well' do
      stub_request(:get, url).with(query: hash_including({})).to_return(json_response([{ id: 1, name: 'Users' }]), json_response([]))

      expect(proxy.any? { it.name == 'Users' }).to be(true)
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
    it 'refuses a resource Zammad routes no search endpoint for' do
      expect { client.ticket_states.search('open') }
        .to raise_error(ZammadAPI::Error, /routes no search endpoint for ZammadAPI::Resources::TicketState/)
    end

    it 'refuses a search of ticket articles, which Zammad indexes but does not route' do
      expect { client.ticket_articles.search('hello') }
        .to raise_error(ZammadAPI::Error, /routes no search endpoint/)
    end

    it 'requests the search endpoint' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: { 'expand' => 'true', 'page' => '1', 'per_page' => ZammadAPI::ResourceProxy::SEARCH_MAX_PER_PAGE.to_s, 'query' => 'support', 'with_total_count' => 'true' })
        .to_return(json_response([]))

      proxy.search('support').to_a
      expect(stub).to have_been_requested
    end

    # The other things a search endpoint narrows by, named on the call that
    # searches rather than passed to where on what it returned.
    context 'with keywords the search endpoint reads' do
      let(:users_search) { "#{ClientHelper::BASE_URL}api/v1/users/search" }

      before { stub_request(:get, /search/).with(query: hash_including({})).to_return(json_response([])) }

      it 'sends ids' do
        client.users.search('x', ids: [1, 2]).to_a
        expect(a_request(:get, users_search).with(query: hash_including('query' => 'x', 'ids' => %w[1 2]))).to have_been_made
      end

      it 'sends role_ids, group_ids and permissions' do
        client.users.search('x', role_ids: [2], group_ids: [3], permissions: ['ticket.agent']).to_a

        expect(a_request(:get, users_search).with(query: hash_including('role_ids' => ['2'], 'group_ids' => ['3'], 'permissions' => ['ticket.agent'])))
          .to have_been_made
      end

      # A list of group ids names no access, which Zammad reads as full. The
      # Hash is how any other access is asked for, and it has to arrive as the
      # pairs User::Search walks: `group_ids[3][]=read`.
      #
      # Read off the URL Faraday built rather than asked of WebMock, which
      # takes a Hash keyed by numbers for an Array and reports
      # `group_ids[][0]=read` for a request that was never sent that way.
      #
      # Every pair naming a group, and not only the three that were written.
      # Looked for as a substring, they were found in a query that named a
      # fourth group beside them as well, and a group nobody asked for is a
      # set of agents the search then keeps.
      it 'sends group_ids as a map of group to access, the way Rails reads a nested parameter back' do
        sent     = nil
        recorder = Class.new(Faraday::Middleware) do
          define_method(:on_request) { |env| sent = URI.decode_www_form(env.url.query) }
        end

        unit_client(middleware: ->(builder) { builder.use(recorder) })
          .users.search('x', group_ids: { 3 => %w[read change], 4 => 'full' }).to_a

        expect(sent.select { |name, _| name.start_with?('group_ids') })
          .to contain_exactly(['group_ids[3][]', 'read'], ['group_ids[3][]', 'change'], ['group_ids[4]', 'full'])
      end

      it 'sends a condition the way Rails reads a nested parameter back' do
        client.tickets.search('x', condition: { 'ticket.state_id' => { operator: 'is', value: [1] } }).to_a

        expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/tickets/search")
          .with(query: hash_including('condition' => { 'ticket.state_id' => { 'operator' => 'is', 'value' => ['1'] } })))
          .to have_been_made
      end

      # `condition: params.require(:condition).permit!`. It is not a Hash,
      # so it was written as its `to_s`, which Zammad cannot read and drops:
      # the search came back unnarrowed.
      it 'sends a condition given as strong parameters the same way' do
        condition = StrongParameters.new('ticket.state_id' => StrongParameters.new(operator: 'is', value: [1]))
        client.tickets.search('x', condition: condition).to_a

        expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/tickets/search")
          .with(query: hash_including('condition' => { 'ticket.state_id' => { 'operator' => 'is', 'value' => ['1'] } })))
          .to have_been_made
      end

      it 'refuses a condition given as strong parameters with nothing in them, as it does an empty Hash' do
        expect { client.tickets.search('x', condition: StrongParameters.new({})) }.to raise_error(ArgumentError, /search was given condition/)
      end

      it 'accepts a keyword spelled as a string' do
        expect(client.users.search('x', 'ids' => [1])).to be_a(ZammadAPI::Collection)
      end

      it 'keeps the term the search was given' do
        client.users.search('smith', ids: [1]).to_a
        expect(a_request(:get, users_search).with(query: hash_including('query' => 'smith'))).to have_been_made
      end

      # A collection is lazy: nothing is sent until it is enumerated. It held
      # the caller's own Array, Hash and String until then, so changing one of
      # them afterwards changed a search that had already been written and
      # checked.
      context 'when what it was given changes before the collection is read' do
        it 'sends the ids it was given' do
          ids    = [1]
          search = client.users.search('x', ids: ids)
          ids << 2
          search.to_a

          expect(a_request(:get, users_search).with(query: hash_including('ids' => ['1']))).to have_been_made
        end

        it 'sends the term it was given' do
          term   = +'smith'
          search = client.users.search(term)
          term << ' jones'
          search.to_a

          expect(a_request(:get, users_search).with(query: hash_including('query' => 'smith'))).to have_been_made
        end

        it 'sends the condition it was given, at every depth' do
          condition = { 'ticket.state_id' => { operator: 'is', value: [1] } }
          search    = client.tickets.search('x', condition: condition)
          condition['ticket.state_id'][:value] << 2
          condition['ticket.owner_id'] = { operator: 'is', value: [3] }
          search.to_a

          expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/tickets/search")
            .with(query: hash_including('condition' => { 'ticket.state_id' => { 'operator' => 'is', 'value' => ['1'] } })))
            .to have_been_made
        end

        it 'carries the copy through page and order' do
          ids    = [1]
          search = client.users.search('x', ids: ids).order(:login).page(2)
          ids << 2
          search.to_a

          expect(a_request(:get, users_search).with(query: hash_including('ids' => ['1'], 'page' => '2', 'sort_by' => 'login,id')))
            .to have_been_made
        end

        it 'leaves what it was given writable' do
          ids = [1]
          client.users.search('x', ids: ids)

          expect(ids).not_to be_frozen
        end
      end
    end

    # Zammad drops a parameter it does not know, so these would come back
    # unnarrowed with nothing to say so.
    context 'with a keyword the search endpoint would drop' do
      it 'refuses an attribute name' do
        expect { proxy.search('support', name: 'Users') }
          .to raise_error(ArgumentError, %r{search does not take name on api/v1/groups: this search endpoint narrows by the term, and by condition, ids, and drops})
      end

      it 'says where an attribute value goes instead' do
        expect { proxy.search('support', name: 'Users') }
          .to raise_error(ArgumentError, /Put an attribute value in the term - search\('state\.name:open'\)/)
      end

      it 'refuses a sort, and names order' do
        expect { proxy.search('support', sort_by: 'name') }
          .to raise_error(ArgumentError, /search does not take sort_by.*sort with search\(term\)\.order\(\.\.\.\)/)
      end

      it 'refuses to replace the search term' do
        expect { proxy.search('login failure', query: 'anything') }.to raise_error(ArgumentError, /search does not take query/)
      end

      %i[page per_page expand only_total_count].each do |owned|
        it "refuses #{owned}, which the collection controls itself" do
          expect { proxy.search('support', owned => 1) }.to raise_error(ArgumentError, /search does not take #{owned}/)
        end
      end

      it 'makes no request' do
        expect { proxy.search('support', name: 'Users') }.to raise_error(ArgumentError)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end
    end

    # model_search_render hands role_ids, group_ids and permissions to the
    # search of every model, and only User::Search reads them. A ticket
    # search given group_ids was sent as written and answered with tickets
    # from every group the client can read.
    context 'with a keyword only the user search reads' do
      it 'refuses group_ids on tickets' do
        expect { client.tickets.search('printer', group_ids: [2]) }
          .to raise_error(ArgumentError, %r{search does not take group_ids on api/v1/tickets: this search endpoint narrows by the term, and by condition, ids, and drops})
      end

      it 'says how tickets are narrowed by group instead' do
        expect { client.tickets.search('printer', group_ids: [2]) }
          .to raise_error(ArgumentError, /or in a condition - search\(term, condition: \{'ticket\.group_id' => \{operator: 'is', value: \[2\]\}\}\)/)
      end

      it 'refuses role_ids and permissions on organizations' do
        expect { client.organizations.search('acme', role_ids: [2], permissions: ['ticket.agent']) }
          .to raise_error(ArgumentError, /search does not take role_ids, permissions on/)
      end

      it 'refuses them on groups' do
        expect { proxy.search('support', group_ids: [1]) }.to raise_error(ArgumentError, /search does not take group_ids on/)
      end

      it 'makes no request' do
        expect { client.tickets.search('printer', group_ids: [2]) }.to raise_error(ArgumentError)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'still takes all three on users, and names them among what that search narrows by' do
        expect(client.users.search('smith', role_ids: [2], group_ids: [3], permissions: ['ticket.agent'])).to be_a(ZammadAPI::Collection)
        expect { client.users.search('smith', active: true) }
          .to raise_error(ArgumentError, /and by condition, ids, role_ids, group_ids, permissions, and drops/)
      end

      it 'still takes condition and ids on every search' do
        expect(client.tickets.search('printer', ids: [1], condition: { 'ticket.group_id' => { operator: 'is', value: [2] } }))
          .to be_a(ZammadAPI::Collection)
      end
    end

    context 'with a resource a caller declared' do
      let(:role_class) do
        Class.new(ZammadAPI::Resources::Base) do
          def self.name = 'Role'

          path 'api/v1/roles'
          searchable true
        end
      end

      it 'takes condition and ids, which every search reads' do
        expect(client.resource(role_class).search('agent', ids: [1])).to be_a(ZammadAPI::Collection)
      end

      it 'refuses a keyword it did not declare' do
        expect { client.resource(role_class).search('agent', permissions: ['admin']) }
          .to raise_error(ArgumentError, %r{search does not take permissions on api/v1/roles})
      end

      it 'takes a keyword it declared' do
        role_class.search_filters :permissions

        expect(client.resource(role_class).search('agent', permissions: ['admin'])).to be_a(ZammadAPI::Collection)
      end
    end

    # Every one of these is refused at the call that wrote it, rather than
    # when the collection is first read some lines away.
    context 'with a keyword it cannot send' do
      it 'refuses a nil value, which no query string can spell' do
        expect { client.users.search('x', ids: nil) }.to raise_error(ArgumentError, /query parameter ids is nil/)
      end

      # Zammad narrows by a keyword only where it is `present?`, so each of
      # these was sent and answered with everything matching the term - for
      # `ids: allowed_ids` with nothing allowed, where none was asked for.
      {
        ids:         [],
        role_ids:    [],
        permissions: [],
        group_ids:   {},
        condition:   {}
      }.each do |name, value|
        it "refuses #{name}: #{value.inspect}, which Zammad reads as no #{name} at all" do
          expect { client.users.search('smith', name => value) }
            .to raise_error(ArgumentError, %r{search was given #{name}: #{Regexp.escape(value.inspect)} on api/v1/users})
        end
      end

      it 'refuses a keyword given as a blank String' do
        expect { client.users.search('smith', ids: ' ') }.to raise_error(ArgumentError, /search was given ids: " "/)
      end

      # `present?` is false for it, so Zammad skips the filter.
      it 'refuses one that holds only a Unicode space' do
        expect { client.users.search('smith', permissions: "\u3000") }.to raise_error(ArgumentError, /search was given permissions:/)
      end

      it 'refuses one that is blank in UTF-16, the way it does one in UTF-8' do
        expect { client.users.search('smith', permissions: "\u3000".encode('UTF-16LE')) }.to raise_error(ArgumentError, /search was given permissions:/)
      end

      it 'takes one given in UTF-16 that is not blank' do
        expect(client.users.search('smith', permissions: 'admin'.encode('UTF-16LE'))).to be_a(ZammadAPI::Collection)
      end

      # Sent as `permissions=`, which is as blank as a String with nothing in
      # it: the check is of what is sent, not of the class it was given as.
      it 'refuses one given as a value whose text is empty' do
        expect { client.users.search('smith', permissions: :'') }.to raise_error(ArgumentError, /search was given permissions: :""/)
      end

      # Nothing is written for an empty Hash, so the request went out with no
      # condition at all.
      it 'refuses a condition that holds nothing but empty Hashes' do
        expect { client.tickets.search('printer', condition: { 'ticket.state_id' => {} }) }
          .to raise_error(ArgumentError, /search was given condition: \{"ticket.state_id" => \{\}\}/)
      end

      # The keyword itself is written, by its other condition, and the one
      # that holds nothing was dropped from the request.
      it 'refuses a condition that holds an empty Hash beside one that is written' do
        condition = { 'ticket.state_id' => {}, 'ticket.title' => { operator: 'contains', value: 'printer' } }

        expect { client.tickets.search('printer', condition: condition) }
          .to raise_error(ArgumentError, /query parameter condition\[ticket\.state_id\] is a Hash with no value in it/)
      end

      it 'refuses group_ids naming a group with nothing under it' do
        expect { client.users.search('smith', group_ids: { 2 => {} }) }.to raise_error(ArgumentError, /search was given group_ids:/)
      end

      it 'says what the search would have come back with' do
        expect { client.users.search('smith', ids: []) }
          .to raise_error(ArgumentError, /everything matching the term, not narrowed to nothing/)
      end

      it 'names every empty keyword at once' do
        expect { client.users.search('smith', ids: [], role_ids: []) }.to raise_error(ArgumentError, /search was given ids: \[\], role_ids: \[\] on/)
      end

      it 'makes no request for one' do
        stub = stub_request(:get, /search/).with(query: hash_including({}))

        expect { client.users.search('smith', ids: []).to_a }.to raise_error(ArgumentError)
        expect(stub).not_to have_been_requested
      end

      # What is nested in a condition is a selector, and Zammad's to read.
      it 'still takes a condition whose value is empty' do
        expect(client.tickets.search('x', condition: { 'ticket.tags' => { operator: 'contains all', value: [] } })).to be_a(ZammadAPI::Collection)
      end

      # An empty list is written, as `condition[ticket.tags][value][]`, so
      # the condition reaches Zammad.
      it 'still takes a condition that holds nothing but an empty list' do
        expect(client.tickets.search('x', condition: { 'ticket.tags' => { value: [] } })).to be_a(ZammadAPI::Collection)
      end

      it 'still takes a value that is not empty for being false or zero' do
        expect(client.users.search('smith', ids: [0])).to be_a(ZammadAPI::Collection)
      end

      it 'refuses two spellings of one keyword rather than dropping a value' do
        expect { client.users.search('x', 'ids' => [1], :ids => [2]) }
          .to raise_error(ArgumentError, /ids was given twice, as "ids" and as :ids/)
      end

      it 'refuses two spellings of one key nested inside a condition' do
        expect { client.tickets.search('x', condition: { 'state_id' => 1, :state_id => 2 }) }
          .to raise_error(ArgumentError, /parameter condition\[state_id\] was given twice/)
      end

      # A group of conditions and a condition share `operator`, which is what
      # lets a query string keep them apart. Two elements that share nothing
      # would reach Zammad as one, so the search says so here.
      it 'refuses a list of conditions a query string cannot keep apart' do
        expect { client.tickets.search('x', condition: { conditions: [{ name: 'ticket.state_id' }, { operator: 'AND' }] }) }
          .to raise_error(ArgumentError, /query parameter condition\[conditions\]\[1\] has no plain value under a key the element before it has/)
      end

      # Read off the URL Faraday built, in the order it was written: WebMock
      # sorts a query before it compares one, and the order is the point.
      # Rails begins the second element at its `operator`, so that has to
      # come before the conditions it holds, or the group is read into the
      # condition before it.
      it 'takes a condition that holds a group of conditions, and sends the group as an element of its own' do
        nested   = { operator: 'OR', conditions: [{ name: 'ticket.state_id', operator: 'is', value: [2] }, { operator: 'AND', conditions: [{ name: 'ticket.group_id', operator: 'is', value: [1] }] }] }
        sent     = nil
        recorder = Class.new(Faraday::Middleware) do
          define_method(:on_request) { |env| sent = URI.decode_www_form(env.url.query).map(&:first) }
        end
        stub_request(:get, /search/).with(query: hash_including({})).to_return(json_response([]))

        search = unit_client(middleware: ->(builder) { builder.use(recorder) }).tickets.search('x', condition: nested)
        expect(search).to be_a(ZammadAPI::Collection)

        search.to_a
        expect(sent.grep(/\Acondition\[conditions\]/)).to eq(
          [
            'condition[conditions][][name]', 'condition[conditions][][operator]', 'condition[conditions][][value][]',
            'condition[conditions][][operator]', 'condition[conditions][][conditions][][name]',
            'condition[conditions][][conditions][][operator]', 'condition[conditions][][conditions][][value][]'
          ]
        )
      end

      it 'still accepts a condition whose keys only look alike' do
        expect(client.tickets.search('x', condition: { 'ticket.state_id' => { operator: 'is' }, 'ticket.group_id' => { operator: 'is' } }))
          .to be_a(ZammadAPI::Collection)
      end
    end

    it 'sorts through order on the collection it returns' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: hash_including('query' => 'support', 'sort_by' => 'name,id', 'order_by' => 'asc,asc'))
        .to_return(json_response([]))

      proxy.search('support').order(:name).to_a
      expect(stub).to have_been_requested
    end

    it 'requires a term' do
      expect { proxy.search }.to raise_error(ArgumentError)
    end

    it 'rejects an empty term' do
      expect { proxy.search('  ') }.to raise_error(ArgumentError, /non-empty query string/)
    end

    # Zammad asks `blank?`, which counts Unicode spaces, and answers a blank
    # term with every record.
    ["\u00A0", "\u3000", "\u3000".encode('UTF-16LE')].each do |blank|
      it "rejects #{blank.inspect}, which Zammad reads as no term" do
        expect { proxy.search(blank) }.to raise_error(ArgumentError, /non-empty query string/)
      end
    end

    it "says that '*' asks for every record" do
      expect { proxy.search('') }.to raise_error(ArgumentError, /Search for '\*' to ask for every record/)
    end

    # How Zammad's own interface lists every user or organization.
    it "sends '*', which asks for every record in so many words" do
      stub = stub_request(:get, "#{url}/search").with(query: hash_including('query' => '*')).to_return(json_response([]))

      proxy.search('*').to_a
      expect(stub).to have_been_requested
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
