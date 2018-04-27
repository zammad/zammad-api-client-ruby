require 'spec_helper'
require 'logger'

describe ZammadAPI::Transport do

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
  let(:logger) do
    Logger.new($stderr).tap do |logger|
      logger.level = Logger::ERROR
    end
  end
  let(:instance) { described_class.new(config, logger) }

  context 'GET' do

    it 'performs GET requests' do
      stub_request(:get, "#{config[:url]}some/path").
         to_return(status: 200, body: "", headers: {})

      instance.get(url: '/some/path')
    end
  end

  context 'on behalf of' do

    it 'responds to #on_behalf_of' do
      expect(instance).to respond_to(:on_behalf_of)
    end
    it 'responds to #on_behalf_of=' do
      expect(instance).to respond_to(:on_behalf_of=)
    end

    it 'sets X-On-Behalf-Of header' do

      on_behalf_of_identifier = 'some_login'

      instance.on_behalf_of = on_behalf_of_identifier

      stub_request(:get, "#{config[:url]}some/path").
               with(  headers: {
                'X-On-Behalf-Of' => on_behalf_of_identifier
                 }).
               to_return(status: 200, body: "", headers: {})

      instance.get(url: '/some/path')
    end

    it 'unsets X-On-Behalf-Of header' do

      on_behalf_of_identifier = 'some_login'

      instance.on_behalf_of = on_behalf_of_identifier
      instance.on_behalf_of = nil

      stub = stub_request(:get, "#{config[:url]}some/path").
               to_return(status: 200, body: "", headers: {})


      # this is kind of a hack/workaround to check if the
      # header was not set/send since webmock doesn't support
      # checks for not existing headers
      request_pattern = stub.request_pattern
      def request_pattern.matches?(request_signature)
        return false if !super
        return true if request_signature.headers.empty?
        !request_signature.headers.key?('X-On-Behalf-Of')
      end

      instance.get(url: '/some/path')
    end
  end
end
