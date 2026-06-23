require 'spec_helper'

describe ZammadAPI do
  it 'has a version number' do
    expect(ZammadAPI::VERSION).not_to be_nil
  end

  context 'failing authentication' do
    Helper.auto_wizard
    client = Helper.client(user: 'not_existing', password: 'not_existing')

    it 'user' do
      expect { client.user.find(1) }.to raise_error(ZammadAPI::ClientError) do |error|
        expect(error.status).to eq(401)
        expect(error.operation).to eq('find object')
        expect(error.resource_class).to eq(ZammadAPI::Resources::User)
      end
    end

    it 'organization' do
      expect { client.organization.find(1) }.to raise_error(ZammadAPI::ClientError)
    end

    it 'group' do
      expect { client.group.find(1) }.to raise_error(ZammadAPI::ClientError)
    end

    it 'ticket_priority' do
      expect { client.ticket_priority.find(1) }.to raise_error(ZammadAPI::ClientError)
    end

    it 'ticket_state' do
      expect { client.ticket_state.find(1) }.to raise_error(ZammadAPI::ClientError)
    end
  end
end
