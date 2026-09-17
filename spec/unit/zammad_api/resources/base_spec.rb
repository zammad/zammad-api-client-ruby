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

    it 'does not leak a path between sibling resources' do
      expect(ZammadAPI::Resources::User.resource_path).to eq('api/v1/users')
    end
  end

  describe 'attributes' do
    subject(:group) { client.group.new(name: 'Support', 'note' => 'from a string key') }

    it 'reads an attribute' do
      expect(group.name).to eq('Support')
    end

    it 'symbolizes string keys supplied by the caller' do
      expect(group.note).to eq('from a string key')
    end

    it 'starts without changes' do
      expect(group).not_to be_changed
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

    it 'is not changed once the value returns to the original' do
      group.name = 'Other'
      group.name = 'Support'
      expect(group).not_to be_changed
    end

    it 'still reads the reassigned value after the change is dropped' do
      group.name = 'Other'
      group.name = 'Support'
      expect(group.name).to eq('Support')
    end

    it 'drops the change when an attribute the record carries is set back to its nil original' do
      carrying_nil = client.group.new(name: 'Support', note: nil)
      carrying_nil.note = 'Renamed'
      carrying_nil.note = nil
      expect(carrying_nil.changes).to be_empty
    end

    # An attribute the record does not carry is not an attribute whose value
    # is nil: Zammad reduces the object it serializes for a permission-scoped
    # client, so the key being absent says nothing about what is stored. Read
    # as a nil original, writing nil to one compared equal, staged nothing and
    # was still merged into the attributes - the write was dropped without a
    # word and the record went on reporting a key Zammad never sent it.
    it 'stages a write of an attribute the record does not carry' do
      group.active = nil
      expect(group.changes).to eq(active: [nil, nil])
    end

    it 'keeps that write staged when it is written twice' do
      group.active = true
      group.active = nil
      expect(group.changes).to eq(active: [nil, nil])
    end

    it 'keeps the attributes it reports in step with the changes it staged' do
      group.active = nil
      expect(group.key?(:active)).to be(group.changes.key?(:active))
    end
  end

  describe 'attribute state a record hands out' do
    subject(:group) { client.group.new(name: 'Support', preferences: { 'note' => 'keep' }) }

    it 'cannot be written through #attributes, which would not stage a change' do
      expect { group.attributes[:name] = 'Sneaky' }.to raise_error(FrozenError)
    end

    it 'cannot be written through a nested value' do
      expect { group.attributes[:preferences][:note] = 'Sneaky' }.to raise_error(FrozenError)
    end

    it 'cannot be written through #changes, which would decide what save sends' do
      group.name = 'Renamed'
      expect { group.changes[:name] = %w[a b] }.to raise_error(FrozenError)
    end

    it 'still records a change through the writer' do
      group.name = 'Renamed'
      expect(group.changes).to eq(name: %w[Support Renamed])
    end

    it 'does not report a change that was never staged' do
      group.to_h[:name] = 'Sneaky'
      expect(group).not_to be_changed
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
      subject(:group) { client.group.new(name: 'Support') }

      before do
        stub_request(:post, url)
          .with(query: { 'expand' => 'true' }, body: '{"name":"Support"}')
          .to_return(json_response({ id: 7, name: 'Support', note: nil }, status: 201))
      end

      it 'returns true' do
        expect(group.save).to be(true)
      end

      it 'posts to the collection path' do
        group.save
        expect(a_request(:post, url).with(query: hash_including({}))).to have_been_made
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
      subject(:group) { client.group.find(1) }

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

      it 'returns true' do
        stub_request(:put, "#{url}/1").with(query: hash_including({}))
          .to_return(json_response({ id: 1, note: 'new' }))

        group.note = 'new'
        expect(group.save).to be(true)
      end

      it 'sends nothing at all when nothing changed' do
        stub = stub_request(:put, "#{url}/1").with(query: hash_including({}))
          .to_return(json_response({ id: 1 }))

        expect(group.save).to be(true)
        expect(stub).not_to have_been_requested
      end

      it 'saves again once something changes' do
        stub_request(:put, "#{url}/1").with(query: hash_including({}), body: '{"note":"new"}')
          .to_return(json_response({ id: 1, note: 'new' }))

        group.save
        group.note = 'new'

        expect(group.save).to be(true)
        expect(group.note).to eq('new')
      end
    end

    it 'raises ParseError when the response is not an object' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response([], status: 201))

      expect { client.group.new(name: 'x').save }
        .to raise_error(ZammadAPI::ParseError, /expected a JSON object, got Array/)
    end

    context 'when Zammad rejects the attributes' do
      subject(:group) { client.group.new }

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

      it 'carries the message Zammad reported' do
        group.save
        expect(group.error.server_message).to eq('Name is required')
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

        expect { client.group.new(name: 'x').save }.to raise_error(ZammadAPI::AuthorizationError)
      end

      it 'still raises for a 500' do
        stub_request(:post, url).with(query: hash_including({}))
          .to_return(json_response({}, status: 500))

        expect { client.group.new(name: 'x').save }.to raise_error(ZammadAPI::ServerError)
      end
    end

    it 'clears a previous error once the record saves' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response({ error: 'Name is required' }, status: 422), json_response({ id: 7, name: 'Support' }))

      group = client.group.new
      group.save
      group.name = 'Support'

      expect(group.save).to be(true)
      expect(group.error).to be_nil
    end

    context 'when the save after a rejected one fails some other way' do
      subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users') }

      before do
        stub_request(:put, "#{url}/1").with(query: hash_including({})).to_return(
          json_response({ error: 'Name is required' }, status: 422),
          json_response({ error: 'not yours' }, status: 403)
        )
        group.name = ''
        group.save
        group.name = 'Support'
      end

      it 'records the first rejection' do
        expect(group.error).to be_a(ZammadAPI::ValidationError)
      end

      it 'clears it rather than reporting it as the second failure' do
        expect { group.save }.to raise_error(ZammadAPI::AuthorizationError)
        expect(group.error).to be_nil
      end
    end
  end

  describe '#save!' do
    subject(:group) { client.group.new(name: 'Support') }

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
    subject(:group) { client.group.new(name: 'Support') }

    it 'stages every attribute as a change' do
      group.assign_attributes(name: 'Renamed', note: 'Why')
      expect(group.changes).to eq(name: %w[Support Renamed], note: [nil, 'Why'])
    end

    it 'accepts string keys' do
      group.assign_attributes('name' => 'Renamed')
      expect(group.name).to eq('Renamed')
    end

    it 'does not save' do
      group.assign_attributes(name: 'Renamed')
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end

    it 'returns the record, so it can be chained' do
      expect(group.assign_attributes(name: 'Renamed')).to be(group)
    end

    it 'drops a change that restores the original value' do
      group.assign_attributes(name: 'Renamed')
      group.assign_attributes(name: 'Support')
      expect(group).not_to be_changed
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

    it 'returns true when the record was stored' do
      stub_request(:put, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, note: 'new' }))

      expect(group.update(note: 'new')).to be(true)
    end

    it 'adopts the attributes from the response' do
      stub_request(:put, "#{url}/1").with(query: hash_including({}))
        .to_return(json_response({ id: 1, name: 'Renamed by Zammad' }))

      group.update(note: 'new')
      expect(group.name).to eq('Renamed by Zammad')
    end

    it 'returns false and records the error when Zammad rejects the attributes' do
      stub_request(:put, "#{url}/1").with(query: hash_including({}))
        .to_return(json_response({ error: 'Note is too long' }, status: 422))

      expect(group.update(note: 'new')).to be(false)
      expect(group.error.server_message).to eq('Note is too long')
    end

    it 'keeps the staged changes after a rejection, so they can be corrected' do
      stub_request(:put, "#{url}/1").with(query: hash_including({}))
        .to_return(json_response({ error: 'Note is too long' }, status: 422))

      group.update(note: 'new')
      expect(group.changes).to eq(note: %w[old new])
    end

    it 'creates a record that has not been saved yet' do
      stub = stub_request(:post, url).with(query: hash_including({}), body: '{"name":"Support"}')
        .to_return(json_response({ id: 7, name: 'Support' }, status: 201))

      expect(client.group.new.update(name: 'Support')).to be(true)
      expect(stub).to have_been_requested
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

    it 'raises ParseError when the response is not an object' do
      stub_request(:get, "#{url}/1").with(query: { 'expand' => 'true' })
        .to_return(json_response([]))

      expect { group.reload }
        .to raise_error(ZammadAPI::ParseError, /expected a JSON object, got Array/)
    end

    it 'raises ParseError when the response is not JSON' do
      stub_request(:get, "#{url}/1").with(query: { 'expand' => 'true' })
        .to_return(status: 200, body: '<html>Gateway Timeout</html>', headers: { 'Content-Type' => 'text/html' })

      expect { group.reload }
        .to raise_error(ZammadAPI::ParseError, /expected a JSON object, got String/)
    end

    it 'keeps the previous attributes when the response cannot be decoded' do
      stub_request(:get, "#{url}/1").with(query: { 'expand' => 'true' })
        .to_return(json_response([]))

      expect { group.reload }.to raise_error(ZammadAPI::ParseError)
      expect(group.name).to eq('Users')
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

    it 'refuses an id that navigates' do
      expect { ZammadAPI::Resources::Group.member_path('..') }.to raise_error(ArgumentError)
    end
  end

  describe '#destroy' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1) }

    it 'deletes the record' do
      stub = stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
      expect(group.destroy).to be(true)
      expect(stub).to have_been_requested
    end

    it 'raises for a record that was never saved' do
      expect { client.group.new.destroy }.to raise_error(ZammadAPI::Error, /has not been saved, so there is nothing to destroy/)
    end

    # `destroy` asked only whether the record was already destroyed, so one
    # built with an id it was simply handed issued a real DELETE for a record
    # it does not stand for. The constructor refuses that id now, so there is
    # no such record left to destroy.
    it 'sends nothing for a record built with an id it was never saved with' do
      stub = stub_request(:delete, "#{url}/99")

      expect { client.group.new(id: 99, name: 'X').destroy }
        .to raise_error(ZammadAPI::Error, /is what addresses this record/)
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

      it 'refuses a save rather than letting it 404' do
        group.name = 'Support'

        expect { group.save }.to raise_error(ZammadAPI::Error, /was destroyed/)
      end

      # `reload` re-read a record that no longer exists and cleared the flag on
      # the way back, so the record came back reporting itself as persisted and
      # its next save issued a PUT against the deleted path.
      it 'refuses a reload rather than resurrecting the record' do
        expect { group.reload }
          .to raise_error(ZammadAPI::Error, /was destroyed, there is nothing to reload/)
      end

      it 'stays destroyed after a refused reload' do
        expect { group.reload }.to raise_error(ZammadAPI::Error)

        expect(group).to be_destroyed
        expect(group).not_to be_persisted
      end

      it 'refuses a second destroy rather than surfacing Zammad\'s 404' do
        expect { group.destroy }
          .to raise_error(ZammadAPI::Error, /was destroyed, there is nothing to destroy/)
      end
    end

    context 'with state staged before it was destroyed' do
      subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users') }

      before do
        stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
        group.name = 'Support'
      end

      it 'drops a change that can never be sent' do
        group.destroy

        expect(group).not_to be_changed
        expect(group.changes).to be_empty
      end

      # Readable as Zammad last served them. The staged write above was never
      # sent, and dropping the change set without it left the record reporting
      # "Support" while `changed?` was false and `changes` was empty - so
      # nothing was left to tell a local edit apart from a value the server
      # gave, in the one state where it can never be saved.
      it 'keeps the attributes readable, so a destroyed record can still be reported on' do
        group.destroy

        expect(group.id).to eq(1)
        expect(group.name).to eq('Users')
      end

      it 'does not report a write Zammad never saw' do
        group.destroy

        expect(group.attributes).to eq({ id: 1, name: 'Users' })
        expect(group.inspect).not_to include('Support')
      end

      it 'refuses the association readers, which would request a record that is gone' do
        group.destroy

        # The guarantee, not the mechanism that was expected to deliver it.
        # This compared the proxy against the one from before the destroy,
        # which clearing the memo satisfied - while `related` went on
        # rebuilding a working proxy on the very next call. It passed for as
        # long as the behaviour it is named for was broken.
        expect { group.related }.to raise_error(ZammadAPI::Error, /was destroyed/)
      end

      it 'drops the failure of a save that is over' do
        stub_request(:put, "#{url}/1").with(query: hash_including({}))
          .to_return(json_response({ error: 'Name is required' }, status: 422))
        group.save

        expect(group.error).to be_a(ZammadAPI::ValidationError)
        group.destroy
        expect(group.error).to be_nil
      end
    end

    # `update` stages before it saves, and `save!` is where the destroyed
    # check used to live. That order left a destroyed record holding a change
    # set that can never be sent - the state destroy clears the staged changes
    # to prevent - so the refusal happens before anything is written.
    context 'when an update is attempted after it was destroyed' do
      before do
        stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
        group.destroy
      end

      it 'refuses the update' do
        expect { group.update(name: 'Renamed') }.to raise_error(ZammadAPI::Error, /was destroyed/)
      end

      it 'refuses the raising update' do
        expect { group.update!(name: 'Renamed') }.to raise_error(ZammadAPI::Error, /was destroyed/)
      end

      it 'leaves nothing staged behind the refusal' do
        begin
          group.update(name: 'Renamed')
        rescue ZammadAPI::Error
          nil
        end

        expect(group).not_to be_changed
        expect(group.changes).to be_empty
      end

      it 'leaves the attributes as they were' do
        begin
          group.update(name: 'Renamed')
        rescue ZammadAPI::Error
          nil
        end

        expect(group.key?(:name)).to be(false)
      end
    end
  end

  describe 'equality' do
    it 'treats two separately fetched records as the same record' do
      stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, name: 'Users' }))

      first_fetch  = client.group.find(1)
      second_fetch = client.group.find(1)

      expect(first_fetch).not_to equal(second_fetch)
      expect(first_fetch).to eq(second_fetch)
    end

    it 'tells records of different resources with the same id apart' do
      group = ZammadAPI::Resources::Group.from_response(unit_transport, id: 1)
      user  = ZammadAPI::Resources::User.from_response(unit_transport, id: 1)

      expect(group).not_to eq(user)
    end

    it 'identifies a record by its id once its first save assigns one' do
      stub_request(:post, url).with(query: hash_including({})).to_return(json_response({ id: 7, name: 'Support' }))
      group = client.group.new(name: 'Support')

      expect(group).not_to eq(ZammadAPI::Resources::Group.from_response(unit_transport, id: 7))
      group.save!
      expect(group).to eq(ZammadAPI::Resources::Group.from_response(unit_transport, id: 7))
    end
  end

  describe '#to_json' do
    it 'renders the attributes rather than the object' do
      group = ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users')

      expect(group.to_json).to eq('{"id":1,"name":"Users"}')
    end
  end

  describe '#inspect' do
    it 'shows the id, state and attributes' do
      group = ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users')
      expect(group.inspect)
        .to eq('#<ZammadAPI::Resources::Group id=1 new_record=false attributes={id: 1, name: "Users"}>')
    end
  end

  describe '.from_response' do
    it 'builds a persisted record' do
      expect(ZammadAPI::Resources::Group.from_response(unit_transport, id: 1)).to be_persisted
    end
  end

  # A plain class-level ivar is not inherited, so a subclass used to inherit
  # every association, the page limit and the searchability, and lose only the
  # API path - raising "does not declare an API path" from a class that
  # plainly did.
  describe 'a resource subclassed by a caller' do
    subject(:subclass) { Class.new(ZammadAPI::Resources::Ticket) { def self.name = 'MyTicket' } }

    it 'inherits the API path' do
      expect(subclass.resource_path).to eq('api/v1/tickets')
    end

    it 'inherits the member path built from it' do
      expect(subclass.member_path(7)).to eq('api/v1/tickets/7')
    end

    it 'inherits searchability' do
      expect(subclass.searchable?).to be(true)
    end

    it 'inherits the page limit' do
      expect(subclass.page_limit).to eq(100)
    end

    it 'inherits the filterable keys' do
      expect(subclass.filterable_keys).to eq([])
    end

    it 'inherits the associations, as it always did' do
      expect(subclass.associations.keys).to eq(ZammadAPI::Resources::Ticket.associations.keys)
    end

    it 'lets a subclass declare a path of its own' do
      own = Class.new(ZammadAPI::Resources::Ticket) { path 'api/v1/my_tickets' }

      expect(own.resource_path).to eq('api/v1/my_tickets')
    end

    # An override has to win even when it is the falsey value, which is why
    # the lookup asks whether the ivar is defined rather than whether it is
    # truthy.
    it 'lets a subclass declare itself unsearchable' do
      own = Class.new(ZammadAPI::Resources::Ticket) { searchable false }

      expect(own.searchable?).to be(false)
    end
  end

  # Declared as bare constants, a misspelled override was silently ignored and
  # the resource kept Base's default: SEARCHEABLE = true left the resource
  # unsearchable, and every find_by on it raised "Zammad routes no search
  # endpoint" with no hint that the declaration was the problem.
  describe 'the endpoint declarations' do
    it 'refuses a misspelled declaration at load' do
      expect { Class.new(described_class) { searcheable true } }
        .to raise_error(NoMethodError, /searcheable/)
    end

    it 'defaults to unsearchable, so an unrouted /search is refused at the call site' do
      expect(Class.new(described_class).searchable?).to be(false)
    end

    it 'defaults to the generic index page limit' do
      expect(Class.new(described_class).page_limit).to eq(described_class::DEFAULT_MAX_PER_PAGE)
    end

    it 'defaults to the generic index query keys' do
      expect(Class.new(described_class).filterable_keys).to eq(described_class::DEFAULT_INDEX_QUERY_KEYS)
    end

    it 'records a declared page limit' do
      expect(Class.new(described_class) { max_per_page 25 }.page_limit).to eq(25)
    end

    it 'records declared query keys' do
      expect(Class.new(described_class) { index_query_keys :sort_by }.filterable_keys).to eq([:sort_by])
    end

    it 'reads a declaration of no query keys' do
      expect(Class.new(described_class) { index_query_keys }.filterable_keys).to eq([])
    end
  end

  # The id is what addresses the record. Staged, it took effect for every path
  # that builds a path from the attributes and not at all for the record those
  # paths then reported on: `group.id = 99; group.destroy` sent DELETE to group
  # 99 and left the record saying group 1 was the one destroyed.
  # The parent is resolved before MEMO_LOCK is taken, because resolving it may
  # build the parent's own proxy through this same method and a Mutex is not
  # reentrant. Folded back inside the lock this raises
  # `ThreadError: deadlock; recursive locking`, and a caller subclassing a
  # resource is the case that lock exists to cover in the first place.
  describe 'the association proxy of a subclass whose parent has none yet' do
    it 'builds without deadlocking on the memo lock' do
      leaf = Class.new(Class.new(ZammadAPI::Resources::Group))

      expect(leaf.related_class).to be_a(Class)
    end
  end

  # `record[:x] = v` reached method_missing as `:[]=`, which the writer branch
  # took for an attribute called `[]`: it staged the index as the value, lost
  # the write, and sent `{"[]": "x"}` on the next save.
  describe '#[]=' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users') }

    it 'stages the attribute it names' do
      group[:note] = 'x'

      expect(group.changes).to eq({ note: [nil, 'x'] })
    end

    it 'reads back through the matching reader' do
      group[:note] = 'x'

      expect(group[:note]).to eq('x')
    end

    it 'takes a string key the way the reader does' do
      group['note'] = 'x'

      expect(group[:note]).to eq('x')
    end

    it 'refuses what the named writer refuses' do
      expect { group[:id] = 9 }.to raise_error(ZammadAPI::Error, /cannot be staged as an attribute/)
    end

    it 'invents no attribute from the operator itself' do
      group[:note] = 'x'

      expect(group.attributes.keys).not_to include(:[])
    end

    it 'is claimed by a record that stages writes' do
      expect(group).to respond_to(:[]=)
    end

    it 'is claimed under either spelling' do
      # rubocop:disable-next Performance/StringIdentifierArgument -- the String spelling is the point
      expect(group.respond_to?('[]=')).to be(true)
    end

    # The production case for recognising a writer by name rather than by a
    # trailing `=`: on a record that stages writes, an operator reached the
    # writer branch and invented an attribute from its stem.
    it 'invents no attribute from a comparison operator' do
      expect { group.public_send(:<=, 5) }.to raise_error(NoMethodError)

      expect(group.attributes.keys).not_to include(:<)
    end

    it 'stages nothing for a comparison operator' do
      expect { group.public_send(:<=, 5) }.to raise_error(NoMethodError)

      expect(group).not_to be_changed
    end
  end

  describe 'writing the id' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users') }

    it 'is refused' do
      expect { group.id = 99 }.to raise_error(ZammadAPI::Error, /is what addresses this record/)
    end

    it 'points at the lookup that was meant' do
      expect { group.id = 99 }.to raise_error(ZammadAPI::Error, /look up the record you meant with find\(99\)/)
    end

    it 'is refused through assign_attributes too' do
      expect { group.assign_attributes(id: 99) }.to raise_error(ZammadAPI::Error, /is what addresses this record/)
    end

    # The message exists to name the id the caller passed, and the pre-check
    # that runs for these two paths dropped it - so a serializer or a form
    # binder, which reach the writer this way, were told to call find(nil).
    it 'names the id that was passed through assign_attributes' do
      expect { group.assign_attributes(id: 99) }.to raise_error(ZammadAPI::Error, /find\(99\)/)
    end

    it 'names the id that was passed through update' do
      expect { group.update(id: 99) }.to raise_error(ZammadAPI::Error, /find\(99\)/)
    end

    it 'names the attribute it refused' do
      expect { group.id = 99 }.to raise_error(ZammadAPI::Error, /Group#id cannot be staged/)
    end

    # Checked before anything is written, not on the way past: refusing
    # mid-loop staged the keys that came first and left the record dirty with
    # half a change set, which is the state `update` takes its own guard one
    # line early to avoid.
    it 'stages nothing at all when one key in the hash is refused' do
      expect { group.assign_attributes(name: 'X', id: 99, note: 'Y') }.to raise_error(ZammadAPI::Error)

      expect(group).not_to be_changed
      expect(group.changes).to be_empty
    end

    it 'leaves the attributes it had already reached alone' do
      expect { group.assign_attributes(name: 'X', id: 99, note: 'Y') }.to raise_error(ZammadAPI::Error)

      expect(group.name).to eq('Users')
    end

    it 'stages nothing through update either' do
      expect { group.update(name: 'X', id: 99) }.to raise_error(ZammadAPI::Error)

      expect(group).not_to be_changed
    end

    # A record that claimed a writer and then raised when it was called would
    # defeat the point of asking, and lead a serializer or form binder straight
    # into the exception it was checking to avoid.
    it 'does not claim a writer it would refuse' do
      expect(group).not_to respond_to(:id=)
    end

    it 'still claims the writers it honours' do
      expect(group).to respond_to(:name=)
    end

    it 'leaves the record addressing what it did before' do
      expect { group.id = 99 }.to raise_error(ZammadAPI::Error)

      expect(group.id).to eq(1)
      expect(group).not_to be_changed
    end

    # The constructor was the one door that did not make this refusal, and
    # the only one whose value reached the wire: a new record is sent in full,
    # so `new(id: 5).save` POSTed the id nothing had checked.
    it 'is refused by the constructor too' do
      expect { client.group.new(id: 5) }.to raise_error(ZammadAPI::Error, /is what addresses this record/)
    end

    it 'still lets a record Zammad served carry one' do
      expect(ZammadAPI::Resources::Group.from_response(unit_transport, id: 5).id).to eq(5)
    end
  end

  # The third way a record ends up persisted without an id, and the one that
  # has nothing to do with a save: Zammad serves a reduced object where the
  # authenticated user may not see the whole record, which is the same thing
  # #write_attribute is written around. Such a record used to be told it "was
  # saved, but the response carried no id" - sending the caller to look at a
  # save that never happened, when what they need is which user the client
  # authenticates as.
  describe 'a record Zammad served without an id' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, name: 'Users') }

    it 'refuses a reload it cannot address' do
      expect { group.reload }.to raise_error(ZammadAPI::Error, /was loaded without an id/)
    end

    it 'points at what this client may read' do
      expect { group.destroy }.to raise_error(ZammadAPI::Error, /check what this client may read/)
    end

    it 'does not claim a save that never happened' do
      expect { group.reload }.to raise_error(ZammadAPI::Error) { |error| expect(error.message).not_to include('was saved') }
    end

    it 'does not tell the caller to save a record Zammad already holds' do
      expect { group.destroy }.to raise_error(ZammadAPI::Error) { |error| expect(error.message).not_to include('save it first') }
    end

    it 'refuses a save it cannot address' do
      group.name = 'Support'

      expect { group.save! }.to raise_error(ZammadAPI::Error, /was loaded without an id/)
    end

    it 'still says the record was saved where a save is what left it this way' do
      stub_request(:post, url).with(query: hash_including({})).to_return(status: 201, body: '<html>proxy</html>')
      new_group = client.group.new(name: 'Support')
      begin
        new_group.save
      rescue ZammadAPI::ParseError
        nil
      end

      expect { new_group.reload }.to raise_error(ZammadAPI::Error, /was saved, but the response carried no id/)
    end
  end

  # What makes a record persisted is that Zammad answered 2xx, not that the
  # answer parsed. Decoded first, a create whose 201 carried an HTML error
  # page from an intervening proxy raised ParseError with the record still
  # looking new - so the ticket existed in Zammad and a retried save POSTed a
  # second one. Marked persisted, the record has no id to be addressed by
  # either, and nothing staged to send, so the retry has to say so rather than
  # take the "nothing to send" short circuit and report success.
  describe 'a create whose success body cannot be parsed' do
    subject(:group) { client.group.new(name: 'Support') }

    before { stub_request(:post, url).with(query: hash_including({})).to_return(status: 201, body: '<html>proxy</html>') }

    it 'still reports the parse failure' do
      expect { group.save }.to raise_error(ZammadAPI::ParseError)
    end

    it 'does not leave the record looking unsaved' do
      begin
        group.save
      rescue ZammadAPI::ParseError
        nil
      end

      expect(group.new_record?).to be(false)
    end

    it 'does not create a second record when the save is retried' do
      2.times do
        group.save
      rescue ZammadAPI::Error
        nil
      end

      expect(a_request(:post, url).with(query: hash_including({}))).to have_been_made.once
    end

    it 'refuses the retried save rather than reporting it stored' do
      begin
        group.save
      rescue ZammadAPI::ParseError
        nil
      end

      expect { group.save }.to raise_error(ZammadAPI::Error, /carried no id/)
    end

    it 'refuses to reload a record it cannot address' do
      begin
        group.save
      rescue ZammadAPI::ParseError
        nil
      end

      expect { group.reload }.to raise_error(ZammadAPI::Error, /carried no id/)
    end

    it 'does not tell the caller to save a record that was already saved' do
      begin
        group.save
      rescue ZammadAPI::ParseError
        nil
      end

      expect { group.destroy }.to raise_error(ZammadAPI::Error, /was saved/)
    end
  end
end
