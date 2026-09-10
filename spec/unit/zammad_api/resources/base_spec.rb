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

    it 'drops the change when a previously unset attribute is set back to nil' do
      group.active = true
      group.active = nil
      expect(group.changes).to be_empty
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

      it 'sends an empty payload when nothing changed' do
        stub = stub_request(:put, "#{url}/1").with(query: hash_including({}), body: '{}')
          .to_return(json_response({ id: 1 }))

        group.save
        expect(stub).to have_been_requested
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

    it 'raises for a record without an id' do
      expect { ZammadAPI::Resources::Group.new(transport).reload }
        .to raise_error(ZammadAPI::Error, /has no id, save it first/)
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

  describe '#destroy' do
    subject(:group) { ZammadAPI::Resources::Group.from_response(unit_transport, id: 1) }

    it 'deletes the record' do
      stub = stub_request(:delete, "#{url}/1").to_return(status: 200, body: '')
      expect(group.destroy).to be(true)
      expect(stub).to have_been_requested
    end

    it 'raises for a record without an id' do
      expect { client.group.new.destroy }.to raise_error(ZammadAPI::Error, /has no id, save it first/)
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
end
