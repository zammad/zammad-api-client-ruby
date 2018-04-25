require 'spec_helper'

describe ZammadAPI do
  it 'has a version number' do
    expect(ZammadAPI::VERSION).not_to be nil
  end

  context 'failing authentication' do

    Helper.auto_wizard
    client = Helper.client(user: 'not_existing', password: 'not_existing')

    it 'user' do
      expect { client.user.find(1) }.to raise_error(RuntimeError)
    end

    it 'organization' do
      expect { client.organization.find(1) }.to raise_error(RuntimeError)
    end

    it 'group' do
      expect { client.group.find(1) }.to raise_error(RuntimeError)
    end

    it 'ticket_priority' do
      expect { client.ticket_priority.find(1) }.to raise_error(RuntimeError)
    end

    it 'ticket_state' do
      expect { client.ticket_state.find(1) }.to raise_error(RuntimeError)
    end
  end
end
