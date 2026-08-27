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

    it 'raises ValidationError when Zammad rejects the record' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response({ error: 'Name is required' }, status: 422))

      expect { client.group.new.save }.to raise_error(ZammadAPI::ValidationError)
    end

    it 'raises ParseError when the response is not an object' do
      stub_request(:post, url).with(query: hash_including({}))
        .to_return(json_response([], status: 201))

      expect { client.group.new(name: 'x').save }
        .to raise_error(ZammadAPI::ParseError, /expected a JSON object, got Array/)
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
