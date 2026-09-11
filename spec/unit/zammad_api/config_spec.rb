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

    it 'leaves the Faraday adapter to Faraday' do
      expect(build.adapter).to be_nil
    end

    it 'installs no extra middleware' do
      expect(build.middleware).to be_nil
    end
  end

  describe 'the Faraday seam' do
    it 'symbolizes an adapter given as a string' do
      expect(build(adapter: 'test').adapter).to eq(:test)
    end

    it 'keeps an adapter given as a symbol' do
      expect(build(adapter: :test).adapter).to eq(:test)
    end

    it 'keeps the middleware callable' do
      hook = ->(builder) { builder }
      expect(build(middleware: hook).middleware).to be(hook)
    end

    it 'rejects middleware that cannot be called' do
      expect { build(middleware: 'not callable') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config middleware needs to respond to call')
    end

    it 'accepts any callable, not only a proc' do
      callable = Class.new { def call(builder) = builder }.new
      expect(build(middleware: callable).middleware).to be(callable)
    end
  end

  describe 'the logger' do
    it 'keeps the logger it is given' do
      logger = Logger.new(IO::NULL)
      expect(build(logger: logger).logger).to be(logger)
    end

    it 'accepts anything that logs at debug, not only a Logger' do
      logger = Class.new { def debug(...) = nil }.new
      expect(build(logger: logger).logger).to be(logger)
    end

    # 1.x took `logger: true` as "log to $stderr".
    it 'rejects a boolean, as 1.x accepted' do
      expect { build(logger: true) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config logger needs to respond to debug')
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

    it 'does not dump the middleware internals' do
      expect(build(middleware: ->(builder) { builder }).inspect).to include('middleware=#<Proc>')
    end

    it 'still shows that no middleware is configured' do
      expect(rendered).to include('middleware=nil')
    end

    it 'is used for to_s as well' do
      config = build(password: 'hunter2')
      expect(config.to_s).to eq(config.inspect)
    end

    context 'with an authenticated proxy' do
      subject(:rendered) { build(proxy: 'http://puser:pproxy-s3cret@proxy.test:8080').inspect }

      it 'redacts the proxy credentials' do
        expect(rendered).not_to include('pproxy-s3cret')
      end

      it 'keeps the proxy host visible' do
        expect(rendered).to include('proxy.test:8080')
      end

      it 'marks the redacted userinfo' do
        expect(rendered).to include('proxy="http://[REDACTED]@proxy.test:8080"')
      end
    end

    it 'leaves a proxy without credentials alone' do
      expect(build(proxy: 'http://proxy.test:8080').inspect).to include('proxy="http://proxy.test:8080"')
    end
  end

  describe 'immutability of string members' do
    it 'freezes the url' do
      expect(build.url).to be_frozen
    end

    it 'does not share the url with the caller' do
      supplied = +'https://zammad.example.com/'
      config   = described_class.new(url: supplied, http_token: 'tok')
      supplied << 'mutated'
      expect(config.url).to eq('https://zammad.example.com/')
    end

    it 'freezes the credentials' do
      config = build(user: 'u', password: +'pw', http_token: nil)
      expect(config.password).to be_frozen
    end

    it 'freezes the proxy' do
      expect(build(proxy: +'http://proxy.test:8080').proxy).to be_frozen
    end

    it 'freezes the user agent' do
      expect(build(user_agent: +'custom/1.0').user_agent).to be_frozen
    end
  end

  it 'is immutable' do
    expect(build).to be_frozen
  end
end
