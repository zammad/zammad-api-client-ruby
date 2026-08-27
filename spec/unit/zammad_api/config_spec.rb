# frozen_string_literal: true

RSpec.describe ZammadAPI::Config do
  def build(url: 'https://zammad.example.com', http_token: 'token', **overrides)
    described_class.new(url: url, http_token: http_token, **overrides)
  end

  describe 'url handling' do
    it 'appends a trailing slash so sub-path installations keep working' do
      expect(build(url: 'https://example.com/zammad').url).to eq('https://example.com/zammad/')
    end

    it 'leaves an existing trailing slash alone' do
      expect(build(url: 'https://example.com/').url).to eq('https://example.com/')
    end

    it 'rejects a missing url' do
      expect { build(url: nil) }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing url in config')
    end

    it 'rejects an empty url' do
      expect { build(url: '') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing url in config')
    end

    it 'rejects a non-http scheme' do
      expect { build(url: 'ftp://example.com') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url needs to start with http:// or https://')
    end
  end

  describe 'credentials' do
    it 'accepts an access token' do
      expect(build(http_token: 'token').authentication_scheme).to eq(:http_token)
    end

    it 'accepts an OAuth2 token' do
      expect(build(http_token: nil, oauth2_token: 'token').authentication_scheme).to eq(:oauth2_token)
    end

    it 'accepts user and password' do
      expect(build(http_token: nil, user: 'u', password: 'p').authentication_scheme).to eq(:basic)
    end

    it 'prefers the access token over other credentials' do
      config = build(http_token: 'token', oauth2_token: 'other', user: 'u', password: 'p')
      expect(config.authentication_scheme).to eq(:http_token)
    end

    it 'rejects a missing user' do
      expect { build(http_token: nil, password: 'p') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
    end

    it 'rejects a missing password' do
      expect { build(http_token: nil, user: 'u') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing password in config')
    end

    it 'treats blank credentials as absent' do
      expect { build(http_token: '', oauth2_token: '', user: '', password: '') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
    end
  end

  describe 'defaults' do
    it 'sets a request timeout' do
      expect(build.timeout).to eq(described_class::DEFAULT_TIMEOUT)
    end

    it 'sets a connection timeout' do
      expect(build.open_timeout).to eq(described_class::DEFAULT_OPEN_TIMEOUT)
    end

    it 'retries transient failures' do
      expect(build.retries).to eq(described_class::DEFAULT_RETRIES)
    end

    it 'identifies itself with the gem version' do
      expect(build.user_agent).to eq("zammad_api-ruby/#{ZammadAPI::VERSION}")
    end

    it 'verifies TLS certificates' do
      expect(build.ssl_verify).to be(true)
    end

    it 'discards log output when no logger is supplied' do
      expect(build.logger).to be_a(Logger)
    end
  end

  describe 'numeric validation' do
    it 'rejects a zero timeout' do
      expect { build(timeout: 0) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config timeout needs to be a positive number')
    end

    it 'rejects a negative open_timeout' do
      expect { build(open_timeout: -1) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config open_timeout needs to be a positive number')
    end

    it 'rejects a non-numeric timeout' do
      expect { build(timeout: 'soon') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config timeout needs to be a positive number')
    end

    it 'rejects negative retries' do
      expect { build(retries: -1) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config retries needs to be a non-negative integer')
    end

    it 'allows disabling retries' do
      expect(build(retries: 0).retries).to eq(0)
    end
  end

  describe '#inspect' do
    subject(:rendered) do
      build(user: 'u', password: 'pw-s3cret', http_token: 'tok-s3cret', oauth2_token: 'oauth-s3cret').inspect
    end

    it 'redacts the password' do
      expect(rendered).not_to include('pw-s3cret')
    end

    it 'redacts the access token' do
      expect(rendered).not_to include('tok-s3cret')
    end

    it 'redacts the OAuth2 token' do
      expect(rendered).not_to include('oauth-s3cret')
    end

    it 'marks redacted values' do
      expect(rendered).to include('password=[REDACTED]')
    end

    it 'keeps non-sensitive values readable' do
      expect(rendered).to include('url="https://zammad.example.com/"')
    end

    it 'does not dump the logger internals' do
      expect(rendered).to include('logger=#<Logger>')
    end

    it 'is used for to_s as well' do
      config = build(password: 'hunter2')
      expect(config.to_s).to eq(config.inspect)
    end
  end

  it 'is immutable' do
    expect(build).to be_frozen
  end
end
