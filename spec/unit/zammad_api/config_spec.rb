# frozen_string_literal: true

require 'pp'

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

    it 'rejects a non-http scheme' do
      expect { build(url: 'ftp://example.com') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url needs to start with http:// or https:// and name a host')
    end

    it 'rejects a url without a host' do
      expect { build(url: 'https://') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url needs to start with http:// or https:// and name a host')
    end

    it 'rejects a url that does not parse' do
      expect { build(url: 'https://zammad example.com') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url is not a valid URL')
    end

    it 'refuses credentials in the url, without quoting them' do
      expect { build(url: 'https://admin:url-s3cret@zammad.example.com/') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url carries credentials: pass user: and password:, or a token, instead')
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

    context 'with more than one way to authenticate' do
      it 'refuses a token beside a user and password' do
        expect { build(http_token: 'token', user: 'u', password: 'p') }
          .to raise_error(ZammadAPI::ConfigurationError, /config names more than one way to authenticate \(http_token, user and password\)/)
      end

      it 'refuses all three, naming each' do
        expect { build(http_token: 'token', oauth2_token: 'other', user: 'u', password: 'p') }
          .to raise_error(ZammadAPI::ConfigurationError, /\(http_token, oauth2_token, user and password\)/)
      end

      it 'refuses a token beside a user that has no password' do
        expect { build(http_token: 'token', user: 'u') }
          .to raise_error(ZammadAPI::ConfigurationError, /more than one way to authenticate/)
      end

      it 'does not count a blank credential as one' do
        expect(build(http_token: 'token', oauth2_token: '', user: nil, password: '').authentication_scheme).to eq(:http_token)
      end
    end

    it 'rejects a missing user' do
      expect { build(http_token: nil, password: 'p') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
    end

    it 'rejects a missing password' do
      expect { build(http_token: nil, user: 'u') }
        .to raise_error(ZammadAPI::ConfigurationError, 'missing password in config')
    end

    it 'strips whitespace around a token' do
      expect(build(http_token: " secret\n").http_token).to eq('secret')
    end

    context 'with a token of only whitespace' do
      it 'treats it as absent, for either token' do
        expect { build(http_token: "  \n") }.to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
        expect { build(http_token: nil, oauth2_token: "  \n") }.to raise_error(ZammadAPI::ConfigurationError, 'missing user in config')
      end

      it 'leaves the scheme it would have replaced in an override alone' do
        expect(build(http_token: nil, user: 'u', password: 'p').with(http_token: "  \n")).to have_attributes(http_token: nil, user: 'u', password: 'p')
      end
    end

    it 'keeps a password of spaces, which basic authentication carries as it is' do
      expect(build(http_token: nil, user: 'u', password: '   ').password).to eq('   ')
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

  describe 'the user agent' do
    it 'falls back to the default when it is nil' do
      expect(build(user_agent: nil).user_agent).to eq("zammad_api-ruby/#{ZammadAPI::VERSION}")
    end

    it 'falls back to the default when it is only whitespace' do
      expect(build(user_agent: " \t\n").user_agent).to eq("zammad_api-ruby/#{ZammadAPI::VERSION}")
    end

    it 'strips whitespace around it' do
      expect(build(user_agent: ' my-app/1.0 ').user_agent).to eq('my-app/1.0')
    end
  end

  describe 'the Faraday seam' do
    it 'symbolizes an adapter given as a string' do
      expect(build(adapter: 'test').adapter).to eq(:test)
    end

    it 'keeps the middleware callable' do
      hook = ->(builder) { builder }
      expect(build(middleware: hook).middleware).to be(hook)
    end
  end

  describe 'the logger' do
    it 'keeps the logger it is given' do
      logger = Logger.new(IO::NULL)
      expect(build(logger: logger).logger).to be(logger)
    end
  end

  describe '#inspect' do
    subject(:rendered) { build(http_token: nil, user: 'u', password: 'pw-s3cret').inspect }

    it 'redacts the password' do
      expect(rendered).not_to include('pw-s3cret')
    end

    it 'redacts the access token' do
      expect(build(http_token: 'tok-s3cret').inspect).not_to include('tok-s3cret')
    end

    it 'redacts the OAuth2 token' do
      expect(build(http_token: nil, oauth2_token: 'oauth-s3cret').inspect).not_to include('oauth-s3cret')
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
      config = build(http_token: nil, user: 'u', password: 'hunter2')
      expect(config.to_s).to eq(config.inspect)
    end

    context 'with an authenticated proxy' do
      subject(:rendered) { build(proxy: 'http://puser:pproxy-s3cret@proxy.test:8080').inspect }

      it 'marks the redacted userinfo' do
        expect(rendered).to include('proxy="http://[REDACTED]@proxy.test:8080"')
      end
    end

    it 'leaves a proxy without credentials alone' do
      expect(build(proxy: 'http://proxy.test:8080').inspect).to include('proxy="http://proxy.test:8080"')
    end
  end

  describe 'pretty printing' do
    it 'prints what inspect prints' do
      config = build(http_token: nil, user: 'u', password: 'hunter2')
      expect(config.pretty_inspect).to eq("#{config.inspect}\n")
    end
  end

  describe '#with' do
    it 'changes an option' do
      expect(build.with(timeout: 5).timeout).to eq(5)
    end

    it 'keeps the rest' do
      expect(build(proxy: 'http://proxy.test:8080').with(timeout: 5).proxy).to eq('http://proxy.test:8080')
    end

    it 're-validates' do
      expect { build.with(url: 'zammad.example.com') }.to raise_error(ZammadAPI::ConfigurationError, /needs to start with http/)
    end

    it 'replaces the authentication scheme rather than adding a second one' do
      derived = build.with(user: 'u', password: 'p')
      expect(derived.to_h.slice(:http_token, :user, :password)).to eq({ http_token: nil, user: 'u', password: 'p' })
    end

    it 'does not read an explicit nil as naming a scheme' do
      expect(build.with(oauth2_token: nil).authentication_scheme).to eq(:http_token)
    end

    it 'can switch to any scheme from any other without naming two at once' do
      switched = build.with(oauth2_token: 'o').with(user: 'u', password: 'p').with(http_token: 't')
      expect(switched.to_h.slice(:http_token, :oauth2_token, :user, :password))
        .to eq({ http_token: 't', oauth2_token: nil, user: nil, password: nil })
    end
  end

  describe '.merge_options' do
    it 'lays the overrides over the options' do
      expect(described_class.merge_options({ url: 'a', timeout: 1 }, { timeout: 2 })).to eq({ url: 'a', timeout: 2 })
    end

    it 'drops the credentials an override replaces' do
      expect(described_class.merge_options({ http_token: 't' }, { oauth2_token: 'o' })).to eq({ oauth2_token: 'o' })
    end

    it 'keeps the other half of a scheme the override names' do
      expect(described_class.merge_options({ user: 'u', password: 'old' }, { password: 'new' }))
        .to eq({ user: 'u', password: 'new' })
    end

    it 'leaves the credentials alone when the overrides name none' do
      expect(described_class.merge_options({ http_token: 't' }, { timeout: 2 })).to eq({ http_token: 't', timeout: 2 })
    end
  end

  describe 'other options' do
    it 'reads an empty proxy as none' do
      expect(build(proxy: '').proxy).to be_nil
    end
  end
end
