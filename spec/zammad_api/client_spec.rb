require 'spec_helper'
require 'logger'

describe ZammadAPI::Client do

  before(:all) do
    WebMock.enable!
  end

  after(:all) do
    WebMock.disable!
  end

  after(:each) do
    WebMock.reset!
  end

  let(:config) { Helper.config }
  let(:instance) { described_class.new(config) }

  context '#perform_on_behalf_of' do

    it 'performs a given block on behalft of a given user' do

      on_behalf_of_identifier = 'some_login'

      stub_request(:get, /#{config[:url]}/).
         with( headers: {
          'X-On-Behalf-Of' => on_behalf_of_identifier
           }).
         to_return(status: 200, body: '{}', headers: {})

      instance.perform_on_behalf_of(on_behalf_of_identifier) do
        instance.user.find(1)
      end
    end

    it "doesn't affect later requests outside of the block" do

      # first perform request on behalf of a login
      on_behalf_of_identifier = 'some_login'

      stub_request(:get, /#{config[:url]}/).
         with( headers: {
          'X-On-Behalf-Of' => on_behalf_of_identifier
           }).
         to_return(status: 200, body: '{}', headers: {})

      instance.perform_on_behalf_of(on_behalf_of_identifier) do
        instance.user.find(1)
      end

      # now without and check that
      # the header isn't set anymore
      stub = stub_request(:get, /#{config[:url]}/).
         to_return(status: 200, body: '{}', headers: {})

      # this is kind of a hack/workaround to check if the
      # header was not set/send since webmock doesn't support
      # checks for not existing headers
      request_pattern = stub.request_pattern
      def request_pattern.matches?(request_signature)
        return false if !super
        return true if request_signature.headers.empty?
        !request_signature.headers.key?('X-On-Behalf-Of')
      end

      instance.user.find(1)
    end
  end
end
