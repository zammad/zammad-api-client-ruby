# frozen_string_literal: true

RSpec.describe ZammadAPI::Resources::Base do
  let(:client) { unit_client }
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  describe 'the path DSL' do
    it 'exposes the declared path' do
      expect(ZammadAPI::Resources::Group.resource_path).to eq('api/v1/groups')
    end

    it 'raises for a resource that declares none' do
      anonymous = Class.new(described_class) do
        def self.name
          'Anonymous'
        end
      end
      expect { anonymous.resource_path }.to raise_error(ZammadAPI::Error, /does not declare an API path/)
    end
  end

  describe 'attributes' do
    subject(:group) { client.groups.new(name: 'Support', 'note' => 'from a string key') }

    it 'reads an attribute' do
      expect(group.name).to eq('Support')
    end

    it 'starts without changes' do
      expect(group).not_to be_changed
    end

    # What a Rails controller holds: not a Hash, but it converts to one.
    context 'when given strong parameters, which convert to a Hash and are not one' do
      subject(:user) { client.users.new(permitted) }

      let(:permitted) { StrongParameters.new(login: 'jane', password: 'hunter2', preferences: StrongParameters.new(locale: 'de')) }

      it 'holds them as attributes of its own' do
        expect(user.attributes).to eq(login: 'jane', password: 'hunter2', preferences: { locale: 'de' })
      end
    end

    it 'records a change as old and new value' do
      group.name = 'Other'
      expect(group.changes).to eq(name: %w[Support Other])
    end

    it 'reports being changed' do
      group.name = 'Other'
      expect(group).to be_changed
    end

    it 'reflects the change when read back' do
      group.name = 'Other'
      expect(group.name).to eq('Other')
    end

    it 'records a change for a previously unset attribute' do
      group.active = true
      expect(group.changes).to eq(active: [nil, true])
    end

    it 'keeps the original value when an attribute is written twice' do
      group.name = 'First'
      group.name = 'Second'
      expect(group.changes).to eq(name: %w[Support Second])
    end

    it 'drops the change when the value returns to the original' do
      group.name = 'Other'
      group.name = 'Support'
      expect(group.changes).to be_empty
    end

    it 'drops the change when an attribute the record carries is set back to its nil original' do
      carrying_nil = client.groups.new(name: 'Support', note: nil)
      carrying_nil.note = 'Renamed'
      carrying_nil.note = nil
      expect(carrying_nil.changes).to be_empty
    end

    # An attribute the record does not carry is not one whose value is nil.
    it 'stages a write of an attribute the record does not carry' do
      group.active = nil
      expect(group.changes).to eq(active: [nil, nil])
    end
  end

  describe 'attribute state a record hands out' do
    subject(:group) { client.groups.new(name: 'Support', preferences: { 'note' => 'keep' }) }

    it 'cannot be written through #changes, which would decide what save sends' do
      group.name = 'Renamed'
      expect { group.changes[:name] = %w[a b] }.to raise_error(FrozenError)
    end

    it 'keeps a value the caller mutates after assigning it' do
      note = +'Mutable'
      group.note = note
      note << ' changed'

      expect(group.note).to eq('Mutable')
    end

    it 'freezes attributes adopted from a response' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response({ id: 7, preferences: { note: 'from the server' } }, status: 201))

      group.save!
      expect { group.attributes[:preferences][:note] << '!' }.to raise_error(FrozenError)
    end
  end

  describe '#save' do
    context 'with a new record' do
      subject(:group) { client.groups.new(name: 'Support') }

      before do
        stub_request(:post, url)
          .with(query: { 'expand' => 'true' }, body: '{"name":"Support"}')
          .to_return(json_response({ id: 7, name: 'Support', note: nil }, status: 201))
      end

      it 'returns true' do
        expect(group.save).to be(true)
      end

      it 'adopts the attributes from the response' do
        group.save
        expect(group.id).to eq(7)
      end

      it 'is no longer a new record' do
        group.save
        expect(group).to be_persisted
      end

      it 'clears the staged changes' do
        group.name = 'Support'
        group.save
        expect(group.changes).to be_empty
      end
    end

    context 'with an existing record' do
      subject(:group) { client.groups.find(1) }

      before do
        stub_request(:get, "#{url}/1").with(query: hash_including({}))
          .to_return(json_response({ id: 1, name: 'Users', note: 'old', active: true }))
      end

      it 'sends only the changed attributes' do
        stub = stub_request(:put, "#{url}/1")
          .with(query: { 'expand' => 'true' }, body: '{"note":"new"}')
          .to_return(json_response({ id: 1, name: 'Users', note: 'new', active: true }))

        group.note = 'new'
        group.save
        expect(stub).to have_been_requested
      end

      it 'sends nothing at all when nothing changed' do
        stub = stub_request(:put, "#{url}/1").with(query: hash_including({}))
          .to_return(json_response({ id: 1 }))

        expect(group.save).to be(true)
        expect(stub).not_to have_been_requested
      end
    end

    it 'raises ParseError when the response is not an object' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response([], status: 201))

      expect { client.groups.new(name: 'x').save }
        .to raise_error(ZammadAPI::ParseError, /expected a JSON object, got Array/)
    end

    context 'when Zammad rejects the attributes' do
      subject(:group) { client.groups.new }

      before do
        stub_request(:post, url).with(query: hash_including({}))
          .to_return(json_response({ error: 'Name is required' }, status: 422))
      end

      it 'returns false instead of raising' do
        expect(group.save).to be(false)
      end

      it 'leaves the validation error in #error' do
        group.save
        expect(group.error).to be_a(ZammadAPI::ValidationError)
      end

      it 'leaves the record unsaved' do
        group.save
        expect(group).to be_new_record
      end

      it 'keeps the staged changes, so the attributes can be corrected and resent' do
        group.name = 'Support'
        group.save
        expect(group.changes).to eq({ name: [nil, 'Support'] })
      end
    end

    context 'when the failure is not a validation error' do
      it 'still raises for a 403' do
        stub_request(:post, url).with(query: hash_including({}))
          .to_return(json_response({ error: 'no' }, status: 403))

        expect { client.groups.new(name: 'x').save }.to raise_error(ZammadAPI::AuthorizationError)
      end
    end

    it 'clears a previous error once the record saves' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response({ error: 'Name is required' }, status: 422), json_response({ id: 7, name: 'Support' }))

      group = client.groups.new
      group.save
      group.name = 'Support'

      expect(group.save).to be(true)
      expect(group.error).to be_nil
    end
  end

  describe '#save!' do
    subject(:group) { client.groups.new(name: 'Support') }

    it 'returns true' do
      stub_request(:post, url).with(query: hash_including({})).to_return(json_response({ id: 7 }, status: 201))

      expect(group.save!).to be(true)
    end

    it 'raises ValidationError when Zammad rejects the record' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response({ error: 'Name is required' }, status: 422))

      expect { group.save! }.to raise_error(ZammadAPI::ValidationError, /Name is required/)
    end

    it 'does not record the error, because it was raised' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response({ error: 'Name is required' }, status: 422))

      expect { group.save! }.to raise_error(ZammadAPI::ValidationError)
      expect(group.error).to be_nil
    end
  end

  describe '#assign_attributes' do
    subject(:group) { client.groups.new(name: 'Support') }

    it 'stages every attribute as a change' do
      group.assign_attributes(name: 'Renamed', note: 'Why')
      expect(group.changes).to eq(name: %w[Support Renamed], note: [nil, 'Why'])
    end

    it 'accepts string keys' do
      group.assign_attributes('name' => 'Renamed')
      expect(group.name).to eq('Renamed')
    end

    it 'returns the record, so it can be chained' do
      expect(group.assign_attributes(name: 'Renamed')).to be(group)
    end

    # `record.update(params.require(:group).permit(:name))`
    context 'with strong parameters' do
      it 'stages what they convert to' do
        group.assign_attributes(StrongParameters.new(name: 'Renamed', note: 'Why'))

        expect(group.changes).to eq(name: %w[Support Renamed], note: [nil, 'Why'])
      end
    end
  end

  describe '#update' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users', note: 'old') }

    it 'sends only the assigned attributes' do
      stub = stub_request(:put, "#{url}/1")
        .with(query: { 'expand' => 'true' }, body: '{"note":"new"}')
        .to_return(json_response({ id: 1, name: 'Users', note: 'new' }))

      group.update(note: 'new')
      expect(stub).to have_been_requested
    end

    it 'returns false and records the error when Zammad rejects the attributes' do
      stub_request(:put, "#{url}/1").with(query: hash_including({}))
        .to_return(json_response({ error: 'Note is too long' }, status: 422))

      expect(group.update(note: 'new')).to be(false)
      expect(group.error.server_message).to eq('Note is too long')
    end
  end

  describe '#update!' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, note: 'old') }

    it 'returns true' do
      stub_request(:put, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1 }))

      expect(group.update!(note: 'new')).to be(true)
    end

    it 'raises when Zammad rejects the attributes' do
      stub_request(:put, "#{url}/1").with(query: hash_including({}))
        .to_return(json_response({ error: 'Note is too long' }, status: 422))

      expect { group.update!(note: 'new') }.to raise_error(ZammadAPI::ValidationError, /Note is too long/)
    end
  end

  describe '#reload' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(transport, id: 1, name: 'Users') }

    let(:transport) { unit_transport }

    before do
      stub_request(:get, "#{url}/1").with(query: { 'expand' => 'true' })
        .to_return(json_response({ id: 1, name: 'Renamed' }))
    end

    it 'refetches the attributes' do
      expect(group.reload.name).to eq('Renamed')
    end

    it 'discards unsaved changes' do
      group.name = 'Local'
      expect(group.reload.changes).to be_empty
    end

    it 'returns itself' do
      expect(group.reload).to be(group)
    end

    it 'raises for a record that was never saved' do
      expect { ZammadAPI::Resources::Group.new(transport).reload }
        .to raise_error(ZammadAPI::Error, /has not been saved, so there is nothing to reload/)
    end
  end

  describe '.member_path' do
    it 'builds the path of one record' do
      expect(ZammadAPI::Resources::Group.member_path(1)).to eq('api/v1/groups/1')
    end

    # ResourceProxy#find, #destroy and every instance method that reaches an
    # endpoint go through here, so the escaping rule is applied once.
    it 'escapes an id that would otherwise leave its segment' do
      expect(ZammadAPI::Resources::Group.member_path('1/../users')).to eq('api/v1/groups/1%2F..%2Fusers')
    end
  end

  describe '#destroy' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1) }

    it 'deletes the record' do
      stub = stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
      expect(group.destroy).to be(true)
      expect(stub).to have_been_requested
    end

    it 'sends nothing for a record built with an id it was never saved with' do
      stub = stub_request(:delete, "#{url}/99")

      expect { client.groups.new(id: 99, name: 'X').destroy }
        .to raise_error(ZammadAPI::Error, /has not been saved, so there is nothing to destroy/)
      expect(stub).not_to have_been_requested
    end

    context 'when the record is gone' do
      before do
        stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
        group.destroy
      end

      it 'reports the record as destroyed' do
        expect(group).to be_destroyed
      end

      it 'no longer reports it as persisted' do
        expect(group).not_to be_persisted
      end

      it 'says so in inspect' do
        expect(group.inspect).to include('destroyed=true')
      end
    end
  end

  describe 'equality' do
    it 'treats two separately fetched records as the same record' do
      stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, name: 'Users' }))

      first_fetch  = client.groups.find(1)
      second_fetch = client.groups.find(1)

      expect(first_fetch).not_to equal(second_fetch)
      expect(first_fetch).to eq(second_fetch)
    end
  end

  describe '#inspect' do
    it 'shows the id, state and attributes' do
      group = ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users')
      expect(group.inspect)
        .to eq('#<ZammadAPI::Resources::Group id=1 new_record=false attributes={id: 1, name: "Users"}>')
    end

    # A record is printed by IRB, by pp, in an RSpec failure and in an
    # exception report, and a user is given a password by staging one.
    context 'with an attribute that names a credential' do
      let(:user) { client.users.new(login: 'x', password: 'hunter2', preferences: { tokens: [{ access_token: 's3cret' }], locale: 'de' }) }

      it 'blanks a staged password' do
        expect(user.inspect).to include('password: "[REDACTED]"').and include('login: "x"')
      end
    end
  end

  describe '.from_response' do
    it 'builds a persisted record' do
      expect(ZammadAPI::Resources::Group.from_response(unit_transport, id: 1)).to be_persisted
    end
  end

  describe 'a resource subclassed by a caller' do
    subject(:subclass) { Class.new(ZammadAPI::Resources::Ticket) { def self.name = 'MyTicket' } }

    it 'inherits the API path' do
      expect(subclass.resource_path).to eq('api/v1/tickets')
    end

    it 'lets a subclass declare a path of its own' do
      own = Class.new(ZammadAPI::Resources::Ticket) { path 'api/v1/my_tickets' }

      expect(own.resource_path).to eq('api/v1/my_tickets')
    end
  end

  describe 'the endpoint declarations' do
    it 'defaults to unsearchable, so an unrouted /search is refused at the call site' do
      expect(Class.new(described_class).searchable?).to be(false)
    end

    it 'defaults to the generic index page limit' do
      expect(Class.new(described_class).page_limit).to eq(described_class::DEFAULT_MAX_PER_PAGE)
    end

    it 'defaults to an index endpoint that sorts, as the generic ones do' do
      expect(Class.new(described_class).sortable?).to be(true)
    end

    it 'records a declared page limit' do
      expect(Class.new(described_class) { max_per_page 25 }.page_limit).to eq(25)
    end

    it 'records a declaration that the index endpoint does not sort' do
      expect(Class.new(described_class) { sortable false }.sortable?).to be(false)
    end

    it 'declares tickets and users unsortable, whose controllers hardcode the order' do
      expect([ZammadAPI::Resources::Ticket, ZammadAPI::Resources::User].map(&:sortable?)).to eq([false, false])
    end
  end

  describe '#[]=' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users') }

    it 'stages the attribute it names' do
      group[:note] = 'x'

      expect(group.changes).to eq({ note: [nil, 'x'] })
    end

    it 'takes a string key the way the reader does' do
      group['note'] = 'x'

      expect(group[:note]).to eq('x')
    end
  end

  describe 'writing the id' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users') }

    it 'is refused' do
      expect { group.id = 99 }
        .to raise_error(ZammadAPI::Error, 'ZammadAPI::Resources::Group#id cannot be changed: it is what addresses this record')
    end

    it 'is taken by the constructor' do
      expect(client.groups.new(id: 5).id).to eq(5)
    end
  end

  describe 'a record Zammad served without an id' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, name: 'Users') }

    it 'refuses a reload it cannot address' do
      expect { group.reload }.to raise_error(ZammadAPI::Error, 'ZammadAPI::Resources::Group has no id, save it first')
    end
  end

  # Zammad answers a create and an update with a JSON object, so a 2xx with
  # anything else is the page of something in front of it: a login page, a
  # captive portal, the default page of a load balancer.
  describe 'a save answered 2xx by something that is not Zammad' do
    def login_page
      { status: 200, body: '<html>Please sign in</html>', headers: { 'Content-Type' => 'text/html' } }
    end

    def swallow
      yield
    rescue ZammadAPI::ParseError
      nil
    end

    context 'when it was a create' do
      subject(:group) { client.groups.new(name: 'Support') }

      before do
        stub_request(:post, url).with(query: hash_including({}))
          .to_return(login_page, json_response({ id: 7, name: 'Support' }, status: 201))
      end

      it 'still reports the parse failure' do
        expect { group.save }.to raise_error(ZammadAPI::ParseError, /expected a JSON object, got String/)
      end

      it 'leaves the record new' do
        swallow { group.save }

        expect(group.new_record?).to be(true)
        expect(group.persisted?).to be(false)
      end
    end
  end
end
