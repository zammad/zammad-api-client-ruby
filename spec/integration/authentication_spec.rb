# frozen_string_literal: true

RSpec.describe ZammadAPI, 'authentication' do
  before(:all) do
    Helper.auto_wizard
  end

  it 'has a version number' do
    expect(ZammadAPI::VERSION).not_to be_nil
  end

  context 'with invalid credentials' do
    let(:client) { Helper.client(user: 'not_existing', password: 'not_existing') }

    it 'raises AuthenticationError with the failing operation' do
      expect { client.user.find(1) }.to raise_error(ZammadAPI::AuthenticationError) do |error|
        expect(error.status).to eq(401)
        expect(error.operation).to eq('find object')
        expect(error.resource_class).to eq(ZammadAPI::Resources::User)
      end
    end

    it 'raises a ClientError, so both can be rescued together' do
      expect { client.user.find(1) }.to raise_error(ZammadAPI::ClientError)
    end

    %i[organization group ticket_priority ticket_state].each do |resource|
      it "raises for #{resource}" do
        expect { client.public_send(resource).find(1) }.to raise_error(ZammadAPI::AuthenticationError)
      end
    end
  end
end
