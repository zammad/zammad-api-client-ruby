require 'spec_helper'
require 'logger'

describe ZammadAPI::Client do
  before(:all) do
    WebMock.enable!
  end

  after(:all) do
    WebMock.disable!
  end

  after do
    WebMock.reset!
  end

  let(:config) { Helper.config }
  let(:instance) { described_class.new(config) }

  describe '.new' do
    it 'raises ConfigurationError when url is missing' do
      expect { described_class.new(config.merge(url: nil)) }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing url in config')
    end

    it 'raises ConfigurationError when url scheme is unsupported' do
      expect { described_class.new(config.merge(url: 'ftp://example.com')) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url needs to start with http:// or https://')
    end

    it 'raises ConfigurationError when user is missing' do
      expect { described_class.new(config.merge(user: nil)) }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
    end

    it 'raises ConfigurationError when password is missing' do
      expect { described_class.new(config.merge(password: nil)) }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing password in config')
    end

    it 'does not require user/password when http_token is supplied' do
      expect { described_class.new(url: config[:url], http_token: 'token') }.not_to raise_error
    end

    it 'does not require user/password when oauth2_token is supplied' do
      expect { described_class.new(url: config[:url], oauth2_token: 'token') }.not_to raise_error
    end
  end

  describe '#method_missing' do
    it 'raises ResourceNotFoundError for unknown resources' do
      expect { instance.does_not_exist }.to raise_error(ZammadAPI::ResourceNotFoundError, /Resource for DoesNotExist does not exist/)
    end

    it 'attaches the underlying NameError as #cause' do
      instance.does_not_exist
    rescue ZammadAPI::ResourceNotFoundError => e
      expect(e.cause).to be_a(NameError)
    end
  end

  describe '#perform_on_behalf_of' do
    it 'performs a given block on behalft of a given user' do
      on_behalf_of_identifier = 'some_login'

      stub_request(:get, /#{config[:url]}/)
        .with(headers: {
                'X-On-Behalf-Of' => on_behalf_of_identifier
              })
        .to_return(status: 200, body: '{}', headers: {})

      instance.perform_on_behalf_of(on_behalf_of_identifier) do
        instance.user.find(1)
      end
    end

    it "doesn't affect later requests outside of the block" do
      # first perform request on behalf of a login
      on_behalf_of_identifier = 'some_login'

      stub_request(:get, /#{config[:url]}/)
        .with(headers: {
                'X-On-Behalf-Of' => on_behalf_of_identifier
              })
        .to_return(status: 200, body: '{}', headers: {})

      instance.perform_on_behalf_of(on_behalf_of_identifier) do
        instance.user.find(1)
      end

      # now without and check that
      # the header isn't set anymore
      stub = stub_request(:get, /#{config[:url]}/)
        .to_return(status: 200, body: '{}', headers: {})

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
