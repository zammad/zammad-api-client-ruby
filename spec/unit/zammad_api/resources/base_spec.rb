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
    subject(:group) { client.groups.new(name: 'Support', 'note' => 'from a string key') }

    it 'reads an attribute' do
      expect(group.name).to eq('Support')
    end

    it 'symbolizes string keys supplied by the caller' do
      expect(group.note).to eq('from a string key')
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

      it 'holds a frozen copy, as it does of a Hash' do
        expect(user.instance_variable_get(:@attributes)).to be_frozen.and be_a(Hash)
      end

      it 'keeps the password out of inspect' do
        expect(user.inspect).to include('password: "[REDACTED]"')
        expect(user.inspect).not_to include('hunter2')
      end

      it 'saves them as a JSON object' do
        stub = stub_request(:post, "#{ClientHelper::BASE_URL}api/v1/users")
          .with(query: hash_including({}), body: '{"login":"jane","password":"hunter2","preferences":{"locale":"de"}}')
          .to_return(json_response({ id: 7, login: 'jane' }, status: 201))

        client.users.create(permitted)
        expect(stub).to have_been_requested
      end

      it 'leaves the refusal of parameters that were not permitted to say so' do
        expect { client.users.new(StrongParameters.new({ login: 'jane' }, permitted: false)) }.to raise_error(StrongParameters::Unfiltered)
      end
    end

    it 'takes nil for no attributes' do
      expect(client.groups.new(nil).attributes).to eq({})
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
    subject(:group) { client.groups.new(name: 'Support', preferences: { 'note' => 'keep' }) }

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
      subject(:group) { client.groups.new(name: 'Support') }

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

        expect { client.groups.new(name: 'x').save }.to raise_error(ZammadAPI::AuthorizationError)
      end

      it 'still raises for a 500' do
        stub_request(:post, url).with(query: hash_including({}))
          .to_return(json_response({}, status: 500))

        expect { client.groups.new(name: 'x').save }.to raise_error(ZammadAPI::ServerError)
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

    it 'keeps a key that cannot become a Symbol, as the constructor does' do
      group.assign_attributes(1 => 'x')

      expect(group.attributes).to eq(client.groups.new(:name => 'Support', 1 => 'x').attributes)
    end

    # `record.update(params.require(:group).permit(:name))`
    context 'with strong parameters' do
      it 'stages what they convert to' do
        group.assign_attributes(StrongParameters.new(name: 'Renamed', note: 'Why'))

        expect(group.changes).to eq(name: %w[Support Renamed], note: [nil, 'Why'])
      end

      it 'stages nothing where they were not permitted' do
        expect { group.assign_attributes(StrongParameters.new({ name: 'Renamed' }, permitted: false)) }.to raise_error(StrongParameters::Unfiltered)
        expect(group).not_to be_changed
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

      expect(client.groups.new.update(name: 'Support')).to be(true)
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
  end

  describe '#destroy' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1) }

    it 'deletes the record' do
      stub = stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
      expect(group.destroy).to be(true)
      expect(stub).to have_been_requested
    end

    it 'takes a 204 for a deleted record' do
      stub_request(:delete, "#{url}/1").to_return(status: 204)

      expect(group.destroy).to be(true)
      expect(group).to be_destroyed
    end

    it 'takes the empty object Zammad answers with for a group' do
      stub_request(:delete, "#{url}/1").to_return(json_response({}))

      expect(group.destroy).to be(true)
      expect(group).to be_destroyed
    end

    it 'raises for a record that was never saved' do
      expect { client.groups.new.destroy }.to raise_error(ZammadAPI::Error, /has not been saved, so there is nothing to destroy/)
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

      it 'leaves a second destroy to Zammad, which answers 404' do
        stub_request(:delete, "#{url}/1").to_return(status: 404, body: '')

        expect { group.destroy }.to raise_error(ZammadAPI::NotFoundError)
      end
    end

    context 'with state staged before it was destroyed' do
      subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1, name: 'Users') }

      before do
        stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
        group.name = 'Support'
      end

      it 'leaves the attributes as they are, the staged change included' do
        group.destroy

        expect(group.name).to eq('Support')
        expect(group.changes).to eq(name: %w[Users Support])
      end
    end
  end

  describe 'a copy made with dup or clone' do
    let(:original) { client.groups.find(1) }

    before do
      stub_request(:get, "#{url}/1").with(query: { expand: 'true' }).to_return(json_response({ id: 1, name: 'A', note: 'n' }))
    end

    %i[dup clone].each do |copier|
      context "with #{copier}" do
        let(:copy) { original.public_send(copier) }

        it 'does not mark the original as changed when the copy is written' do
          copy.name = 'X'
          expect(original).not_to be_changed
        end

        it 'does not stage the write on the original' do
          copy.name = 'X'
          expect(original.changes).to eq({})
        end

        it 'stages the write on the copy' do
          copy.name = 'X'
          expect(copy.changes).to eq({ name: %w[A X] })
        end

        it 'sends nothing when the original is saved after the copy was written' do
          copy.name = 'X'
          original.save
          expect(a_request(:put, "#{url}/1")).not_to have_been_made
        end

        it 'does not stage a write to the original on the copy' do
          copy
          original.name = 'Y'
          expect(copy.changes).to eq({})
        end

        it 'carries over what was staged when it was made' do
          original.name = 'Y'
          expect(copy.changes).to eq({ name: %w[A Y] })
        end

        it 'keeps those two change sets apart afterwards' do
          original.name = 'Y'
          copy.note = 'other'
          expect(original.changes.keys).to eq([:name])
        end

        it 'is still the same Zammad record' do
          expect(copy).to eq(original)
        end

        it 'gets association readers of its own, not the ones bound to the original' do
          expect(copy.related).not_to be(original.related)
        end
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

    it 'tells records of different resources with the same id apart' do
      group = ZammadAPI::Resources::Group.from_response(unit_transport, id: 1)
      user  = ZammadAPI::Resources::User.from_response(unit_transport, id: 1)

      expect(group).not_to eq(user)
    end

    context 'with a record read through two clients for one instance' do
      let(:record) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1) }

      it 'is the same record through a client with other options' do
        other = ZammadAPI::Resources::Group.from_response(unit_transport(timeout: 5, http_token: 'another'), id: 1)

        expect(record).to eq(other)
        expect(record.hash).to eq(other.hash)
      end

      it 'is the same record through an on_behalf_of scope' do
        scoped = ZammadAPI::Resources::Group.from_response(unit_transport.with_on_behalf_of('agent@example.com'), id: 1)

        expect([record, scoped].uniq.size).to eq(1)
      end

      it 'is the same record whether or not the url was written with its trailing slash' do
        other = ZammadAPI::Resources::Group.from_response(unit_transport(url: ClientHelper::BASE_URL.chomp('/')), id: 1)

        expect(record).to eq(other)
      end
    end

    it 'identifies a record by its id once its first save assigns one' do
      stub_request(:post, url).with(query: hash_including({})).to_return(json_response({ id: 7, name: 'Support' }))
      group = client.groups.new(name: 'Support')

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

    # A record is printed by IRB, by pp, in an RSpec failure and in an
    # exception report, and a user is given a password by staging one.
    context 'with an attribute that names a credential' do
      let(:user) { client.users.new(login: 'x', password: 'hunter2', preferences: { tokens: [{ access_token: 's3cret' }], locale: 'de' }) }

      it 'blanks a staged password' do
        expect(user.inspect).to include('password: "[REDACTED]"').and include('login: "x"')
      end

      it 'does not print the password anywhere' do
        expect(user.inspect).not_to include('hunter2')
      end

      it 'blanks a credential nested in another attribute' do
        expect(user.inspect).not_to include('s3cret')
      end

      it 'leaves what sits beside a nested credential readable' do
        expect(user.inspect).to include('locale: "de"')
      end

      it 'is what pp prints as well' do
        expect(PP.pp(user, +'')).not_to include('hunter2')
      end

      it 'blanks one that was written after the record was built' do
        user.password = 'correct horse'
        expect(user.inspect).not_to include('correct horse')
      end

      it 'still hands the value over to what sends it' do
        expect(user.attributes[:password]).to eq('hunter2')
        expect(user.to_h[:password]).to eq('hunter2')
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

    it 'inherits the member path built from it' do
      expect(subclass.member_path(7)).to eq('api/v1/tickets/7')
    end

    it 'inherits searchability' do
      expect(subclass.searchable?).to be(true)
    end

    it 'inherits the page limit' do
      expect(subclass.page_limit).to eq(100)
    end

    it 'inherits whether the index endpoint sorts' do
      expect(subclass.sortable?).to be(false)
    end

    it 'inherits the associations' do
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

    it 'reads back through the matching reader' do
      group[:note] = 'x'

      expect(group[:note]).to eq('x')
    end

    it 'takes a string key the way the reader does' do
      group['note'] = 'x'

      expect(group[:note]).to eq('x')
    end

    it 'refuses what the named writer refuses' do
      expect { group[:id] = 9 }.to raise_error(ZammadAPI::Error, /cannot be changed/)
    end

    it 'invents no attribute from the operator itself' do
      group[:note] = 'x'

      expect(group.attributes.keys).not_to include(:[])
    end

    it 'is claimed by a record that stages writes' do
      expect(group).to respond_to(:[]=)
    end

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
      expect { group.id = 99 }
        .to raise_error(ZammadAPI::Error, 'ZammadAPI::Resources::Group#id cannot be changed: it is what addresses this record')
    end

    it 'is refused through assign_attributes too' do
      expect { group.assign_attributes(id: 99) }.to raise_error(ZammadAPI::Error, /cannot be changed/)
    end

    it 'is refused through update too, and sends nothing' do
      expect { group.update(id: 99) }.to raise_error(ZammadAPI::Error, /cannot be changed/)
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end

    it 'leaves the record addressing what it did before' do
      expect { group.id = 99 }.to raise_error(ZammadAPI::Error)

      expect(group.id).to eq(1)
      expect(group).not_to be_changed
    end

    it 'is taken by the constructor' do
      expect(client.groups.new(id: 5).id).to eq(5)
    end

    it 'still lets a record Zammad served carry one' do
      expect(ZammadAPI::Resources::Group.from_response(unit_transport, id: 5).id).to eq(5)
    end
  end

  describe 'a record Zammad served without an id' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, name: 'Users') }

    it 'refuses a reload it cannot address' do
      expect { group.reload }.to raise_error(ZammadAPI::Error, 'ZammadAPI::Resources::Group has no id, save it first')
    end

    it 'refuses a destroy it cannot address' do
      expect { group.destroy }.to raise_error(ZammadAPI::Error, /has no id/)
    end

    it 'refuses a save it cannot address' do
      group.name = 'Support'

      expect { group.save! }.to raise_error(ZammadAPI::Error, /has no id/)
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

      it 'sends the record with the next save, which is the first Zammad sees' do
        swallow { group.save }

        expect(group.save).to be(true)
        expect(group.id).to eq(7)
        expect(a_request(:post, url).with(query: hash_including({}), body: { name: 'Support' })).to have_been_made.twice
      end
    end

    context 'when it was an update' do
      subject(:ticket) { client.tickets.find(1) }

      let(:ticket_url) { "#{ClientHelper::BASE_URL}api/v1/tickets/1" }

      before do
        stub_request(:get, ticket_url).with(query: hash_including({})).to_return(json_response({ id: 1, title: 'Help', state: 'open' }))
        stub_request(:put, ticket_url).with(query: hash_including({}))
          .to_return(login_page, json_response({ id: 1, title: 'Help', state: 'closed' }))

        swallow { ticket.update(state: 'closed') }
      end

      it 'keeps the changes staged' do
        expect(ticket.changes).to eq(state: %w[open closed])
      end

      it 'sends them with the next save rather than reporting it stored' do
        expect(ticket.save).to be(true)
        expect(a_request(:put, ticket_url).with(query: hash_including({}), body: { state: 'closed' })).to have_been_made.twice
        expect(ticket.changed?).to be(false)
      end
    end

    it 'takes a 2xx that names no content type the same way' do
      stub_request(:post, url).with(query: hash_including({})).to_return(status: 200, body: 'OK')
      group = client.groups.new(name: 'Support')
      swallow { group.save }

      expect(group.new_record?).to be(true)
    end

    it 'takes a body that says it is JSON and cannot be read the same way' do
      stub_request(:post, url).with(query: hash_including({})).to_return(unreadable_json_response(status: 201))
      group = client.groups.new(name: 'Support')

      expect { group.save }.to raise_error(ZammadAPI::ParseError)
      expect(group.new_record?).to be(true)
    end
  end
end
