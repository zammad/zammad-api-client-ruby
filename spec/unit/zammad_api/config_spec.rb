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

    # Appended blindly, the slash landed behind the query string and every
    # request was resolved against a base ending in `?tenant=acme/`.
    it 'puts the trailing slash on the path, not behind a query string' do
      expect(build(url: 'https://example.com/zammad?tenant=acme').url)
        .to eq('https://example.com/zammad/?tenant=acme')
    end

    it 'puts the trailing slash on the path, not behind a fragment' do
      expect(build(url: 'https://example.com/zammad#top').url)
        .to eq('https://example.com/zammad/#top')
    end

    # Accepted, this failed deep inside the adapter on the first request
    # instead of here.
    it 'rejects a scheme with no host after it' do
      expect { build(url: 'https://') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url needs a host after the scheme, got "https://"')
    end

    # URI(...) is what a caller reaches for, and it prints as the URL, so it
    # reached String#end_with? and died there as a NoMethodError - past the
    # ConfigurationError the constructor is documented to raise.
    it 'rejects a url that is not a string' do
      expect { build(url: URI('https://example.com/')) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config url needs to be a string, got URI::HTTPS')
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

  describe 'the user agent' do
    # Handed to Faraday as a nil header, Faraday filled in its own, so the gem
    # stopped identifying itself in the instance log an operator greps to find
    # its requests - on every request, with nothing said about it.
    it 'falls back to the default when it is nil' do
      expect(build(user_agent: nil).user_agent).to eq("zammad_api-ruby/#{ZammadAPI::VERSION}")
    end

    it 'falls back to the default when it is empty' do
      expect(build(user_agent: '').user_agent).to eq("zammad_api-ruby/#{ZammadAPI::VERSION}")
    end

    it 'rejects one that is not a string' do
      expect { build(user_agent: 42) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config user_agent needs to be a string')
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

    it 'redacts a proxy password carrying an unencoded @' do
      rendered = build(proxy: 'http://puser:pa@ss-s3cret@proxy.test:8080').inspect

      expect(rendered).to include('proxy="http://[REDACTED]@proxy.test:8080"')
      expect(rendered).not_to include('ss-s3cret')
    end

    it 'leaves a proxy without credentials alone' do
      expect(build(proxy: 'http://proxy.test:8080').inspect).to include('proxy="http://proxy.test:8080"')
    end

    # The shape an http_proxy style setting is copied out of. Anchored on a
    # `://` lookbehind, the redaction never fired and the password went into
    # every log line and exception report this class promises to be safe in.
    it 'redacts the credentials of a proxy configured without a scheme' do
      rendered = build(proxy: 'puser:pproxy-s3cret@proxy.test:8080').inspect

      expect(rendered).to include('proxy="[REDACTED]@proxy.test:8080"')
      expect(rendered).not_to include('pproxy-s3cret')
    end

    it 'leaves a scheme-less proxy without credentials alone' do
      expect(build(proxy: 'proxy.test:8080').inspect).to include('proxy="proxy.test:8080"')
    end

    context 'with credentials in the instance url' do
      subject(:rendered) { build(url: 'https://admin:url-s3cret@zammad.example.com/').inspect }

      it 'redacts them' do
        expect(rendered).not_to include('url-s3cret')
      end

      it 'keeps the host visible' do
        expect(rendered).to include('zammad.example.com')
      end

      it 'marks the redacted userinfo' do
        expect(rendered).to include('url="https://[REDACTED]@zammad.example.com/"')
      end
    end

    it 'leaves a url without credentials alone' do
      expect(build(url: 'https://zammad.example.com/').inspect).to include('url="https://zammad.example.com/"')
    end
  end

  describe '#redacted_url' do
    it 'blanks inline credentials' do
      expect(build(url: 'https://admin:s3cret@zammad.example.com/').redacted_url)
        .to eq('https://[REDACTED]@zammad.example.com/')
    end

    # Anchoring on the first @ left the tail of the password in the rendered
    # URL, which is interpolated into every ConnectionError message.
    it 'blanks a password carrying an unencoded @' do
      expect(build(url: 'https://admin:pa@ss-s3cret@zammad.example.com/').redacted_url)
        .to eq('https://[REDACTED]@zammad.example.com/')
    end

    it 'leaves an @ in the path alone' do
      expect(build(url: 'https://zammad.example.com/tenant@acme/').redacted_url)
        .to eq('https://zammad.example.com/tenant@acme/')
    end

    # Bounded only by the path, the match crossed into the query string and
    # rendered a host that does not exist - into every ConnectionError message.
    it 'leaves an @ in a query string alone' do
      expect(build(url: 'https://zammad.example.com?tenant=a@acme').redacted_url)
        .to eq('https://zammad.example.com/?tenant=a@acme')
    end

    it 'leaves an @ in a fragment alone' do
      expect(build(url: 'https://zammad.example.com#a@b').redacted_url)
        .to eq('https://zammad.example.com/#a@b')
    end

    it 'still blanks credentials on a url that also carries an @ later on' do
      expect(build(url: 'https://admin:s3cret@zammad.example.com/tenant@acme/').redacted_url)
        .to eq('https://[REDACTED]@zammad.example.com/tenant@acme/')
    end

    it 'leaves a url without credentials alone' do
      expect(build(url: 'https://zammad.example.com/').redacted_url).to eq('https://zammad.example.com/')
    end

    it 'does not change what requests are sent to' do
      config = build(url: 'https://admin:s3cret@zammad.example.com/')
      expect(config.url).to eq('https://admin:s3cret@zammad.example.com/')
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

  # Every other option is checked up front; these three were not, so a bad
  # value escaped the ConfigurationError that building a client is documented
  # to need - two as a bare NoMethodError, one by silently staying on.
  describe 'option validation' do
    it 'rejects a proxy that is not a string' do
      expect { build(proxy: URI('http://user:secret@proxy:3128')) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config proxy needs to be a string, got URI::HTTP')
    end

    # The whole point of refusing it: a URI reached String#sub inside #inspect
    # and died there, so the object this class documents as safe to log raised
    # at the moment something logged it.
    it 'keeps a proxy-bearing config renderable' do
      expect { build(proxy: 'http://user:secret@proxy:3128').inspect }.not_to raise_error
    end

    it 'redacts the credentials in a proxy it renders' do
      rendered = build(proxy: 'http://user:secret@proxy:3128').inspect

      expect(rendered).to include('proxy="http://[REDACTED]@proxy:3128"')
      expect(rendered).not_to include('secret')
    end

    it 'rejects an adapter that cannot be a symbol' do
      expect { build(adapter: 1) }
        .to raise_error(ZammadAPI::ConfigurationError, 'config adapter needs to be a symbol or a string, got Integer')
    end

    # `adapter: true` is the 1.x-flavoured mistake: it answered to_sym on
    # nothing and raised NoMethodError from inside the constructor.
    it 'rejects a boolean adapter' do
      expect { build(adapter: true) }
        .to raise_error(ZammadAPI::ConfigurationError, /config adapter needs to be a symbol or a string/)
    end

    it 'accepts an adapter named as a string' do
      expect(build(adapter: 'net_http').adapter).to eq(:net_http)
    end

    # Read from an environment variable this is the string "false", which is
    # truthy, so verification stayed on while the caller believed they had
    # turned it off.
    it 'rejects an ssl_verify that is not a boolean' do
      expect { build(ssl_verify: 'false') }
        .to raise_error(ZammadAPI::ConfigurationError, 'config ssl_verify needs to be true or false, got "false"')
    end

    it 'accepts ssl_verify: false' do
      expect(build(ssl_verify: false).ssl_verify).to be(false)
    end
  end
end
