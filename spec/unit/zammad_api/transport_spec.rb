# frozen_string_literal: true

require 'bigdecimal'
require 'pp'

RSpec.describe ZammadAPI::Transport do
  let(:url) { "#{ClientHelper::BASE_URL}api/v1/groups" }

  describe 'authentication' do
    it 'sends a Token header for an access token' do
      stub = stub_request(:get, url).with(headers: { 'Authorization' => 'Token test-token' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'sends a Bearer header for an OAuth2 token' do
      stub = stub_request(:get, url).with(headers: { 'Authorization' => 'Bearer oauth' }).to_return(json_response([]))
      unit_transport(http_token: nil, oauth2_token: 'oauth').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'sends basic auth for user and password' do
      stub = stub_request(:get, url).with(basic_auth: %w[u p]).to_return(json_response([]))
      unit_transport(http_token: nil, user: 'u', password: 'p').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end
  end

  describe 'default headers' do
    it 'identifies the client' do
      stub = stub_request(:get, url)
        .with(headers: { 'User-Agent' => "zammad_api-ruby/#{ZammadAPI::VERSION}" })
        .to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'asks for JSON' do
      stub = stub_request(:get, url).with(headers: { 'Accept' => 'application/json' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'allows overriding the user agent' do
      stub = stub_request(:get, url).with(headers: { 'User-Agent' => 'my-app/1.0' }).to_return(json_response([]))
      unit_transport(user_agent: 'my-app/1.0').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    # Net::HTTP refused it at the request, quoting the value.
    it 'refuses a raw request header with a line break inside it, without quoting it' do
      expect { described_class.stringify_headers('X-Api-Key' => "abc\r\nsecret") }
        .to raise_error(ArgumentError, /\Aheader x-api-key holds a line break, which a header cannot carry/) { |error|
          expect(error.message).not_to include('secret')
        }
    end

    # The check stripped the value first, which raises for such text, and
    # read the error as "no line break".
    it 'refuses a line break beside a byte sequence that is invalid in the encoding' do
      expect { described_class.stringify_headers('Accept-Language' => "de\xFF\nX-Injected: secret") }
        .to raise_error(ArgumentError, /\Aheader accept-language holds a line break, which a header cannot carry/) { |error|
          expect(error.message).not_to include('secret')
        }
    end

    it 'takes one that only ends in a line break, which Net::HTTP strips' do
      expect(described_class.stringify_headers('X-Note' => "abc\n")).to eq('x-note' => "abc\n")
    end

    it 'carries a header value given in UTF-16 as the same text in UTF-8' do
      expect(described_class.stringify_headers('X-Note' => 'ä'.encode('UTF-16LE'))).to eq('x-note' => 'ä')
    end
  end

  # Only the value of a raw request's header was checked. The Net::HTTP that
  # ships with Ruby 3.4 and 4.0 writes a name to the socket as it is, so one
  # holding a line break sent header lines of its own, a From or an
  # Authorization among them.
  describe 'header names' do
    it 'downcases a name, and takes it as text or as a Symbol' do
      expect(described_class.stringify_headers('Accept-Language' => 'de', :'X-Trace' => 'abc')).to eq('accept-language' => 'de', 'x-trace' => 'abc')
    end

    it 'takes every sign a name may hold' do
      expect(described_class.stringify_headers("X!#$%&'*+-.^_`|~9" => 'v')).to eq("x!#$%&'*+-.^_`|~9" => 'v')
    end

    it 'refuses a name with a line break in it, and header lines of its own after that' do
      expect { described_class.stringify_headers("X-A: 1\r\nFrom: admin@example.com\r\nX-B" => 'v') }
        .to raise_error(ArgumentError, /\Athe header name that begins "X-A" goes on with a character no header name carries/)
    end

    it 'does not quote what follows, which may be a credential' do
      expect { described_class.stringify_headers("X-A: 1\r\nAuthorization: Token name-s3cret\r\nX-B" => 'v') }
        .to raise_error(ArgumentError) { |error| expect(error.message).not_to include('name-s3cret') }
    end

    # Each passed the lookup that refuses a From header by name.
    ['From ', ' From', "From\t", 'From:', "From\n"].each do |name|
      it "refuses #{name.inspect}, which is no spelling of a header" do
        expect { described_class.stringify_headers(name => 'agent@example.com') }.to raise_error(ArgumentError, /no header name carries/)
      end
    end

    ['', nil, 'X Trace', 'Träce', 'X-Trace'.encode('UTF-16LE')].each do |name|
      it "refuses #{name.inspect}" do
        expect { described_class.stringify_headers(name => 'abc') }.to raise_error(ArgumentError, /no header name carries/)
      end
    end

    # `downcase` raises for such text, with a message of its own.
    it 'refuses a name with a byte sequence that is invalid in its encoding' do
      expect { described_class.stringify_headers("X-\xFFTrace" => 'abc') }
        .to raise_error(ArgumentError, /\Athe header name that begins "X-" goes on with a character no header name carries/)
    end

    it 'makes no request for one, and logs none' do
      log = StringIO.new

      expect { unit_transport(logger: Logger.new(log)).get('api/v1/groups', operation: 'test', headers: { "X-A\r\nFrom: x" => 'v' }) }
        .to raise_error(ArgumentError)
      expect(log.string).to be_empty
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end
  end

  describe 'base url handling' do
    it 'keeps a sub-path prefix in front of the request path' do
      stub = stub_request(:get, 'http://zammad.test/helpdesk/api/v1/groups').to_return(json_response([]))
      unit_transport(url: 'http://zammad.test/helpdesk').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end
  end

  describe 'query parameters' do
    it 'encodes scalars as strings' do
      stub = stub_request(:get, url).with(query: { 'page' => '1', 'expand' => 'true' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test', query: { page: 1, expand: true })
      expect(stub).to have_been_requested
    end

    it 'escapes values that need it' do
      stub = stub_request(:get, "#{url}/search").with(query: { 'query' => 'a b&c' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups/search', operation: 'test', query: { query: 'a b&c' })
      expect(stub).to have_been_requested
    end

    it 'encodes arrays' do
      stub = stub_request(:get, url).with(query: { 'ids' => %w[1 2] }).to_return(json_response([]))
      unit_transport.get('api/v1/groups', operation: 'test', query: { ids: [1, 2] })
      expect(stub).to have_been_requested
    end

    # `condition` is what Zammad's search endpoints narrow by, and it is
    # nested. Rendered with to_s it went out as a Ruby inspect string, which
    # Zammad dropped, answering an unnarrowed search.
    it 'encodes a nested hash the way Rails reads it back' do
      stub = stub_request(:get, "#{url}/search")
        .with(query: { 'condition' => { 'ticket.state_id' => { 'operator' => 'is', 'value' => %w[1 2] } } })
        .to_return(json_response([]))
      unit_transport.get(
        'api/v1/groups/search',
        operation: 'test',
        query:     { condition: { 'ticket.state_id' => { operator: 'is', value: [1, 2] } } }
      )
      expect(stub).to have_been_requested
    end

    it 'stringifies the scalars inside a nested hash' do
      expect(described_class.stringify_query(condition: { open: { active: true, limit: 5 } }))
        .to eq({ 'condition' => { 'open' => { 'active' => 'true', 'limit' => '5' } } })
    end

    # Whatever was neither a Hash nor an Array went on the wire as its
    # `to_s`, which names nothing, and Zammad narrowed by it all the same.
    context 'with a value a query string has no spelling for' do
      { 'a Set' => Set[1, 2], 'a Range' => (1..3), 'a Time' => Time.at(0), 'any other object' => Object.new }.each do |kind, value|
        it "refuses #{kind} by its class, without quoting it" do
          expect { described_class.stringify_query(ids: value) }
            .to raise_error(ArgumentError, /\Aquery parameter ids was given as #{value.class}, and a query string carries text, Integers, Floats and booleans/) { |error|
              expect(error.message).not_to include(value.to_s)
            }
        end
      end

      it 'refuses one inside a list, naming where' do
        expect { described_class.stringify_query(ids: [1, Set[2]]) }.to raise_error(ArgumentError, /\Aquery parameter ids\[1\] was given as Set/)
      end

      it 'refuses one inside a structure, naming where' do
        expect { described_class.stringify_query(condition: { 'ticket.id' => { operator: 'is', value: (1..3) } }) }
          .to raise_error(ArgumentError, /\Aquery parameter condition\[ticket\.id\]\[value\] was given as Range/)
      end

      it 'sends nothing for a request that carries one' do
        expect { unit_transport.get('api/v1/groups', operation: 'test', query: { ids: Set[1, 2] }) }.to raise_error(ArgumentError)
        expect(a_request(:any, //)).not_to have_been_made
      end

      it 'still writes text, a Symbol, a number and a boolean' do
        expect(described_class.stringify_query(a: 'x', b: :y, c: 1, d: 1.5, e: true, f: false))
          .to eq({ 'a' => 'x', 'b' => 'y', 'c' => '1', 'd' => '1.5', 'e' => 'true', 'f' => 'false' })
      end

      # Every Numeric was taken for a number a query string spells, and
      # these print as `0.5e1`, `1/2` and `1+2i`.
      { 'a BigDecimal' => BigDecimal('5'), 'a Rational' => Rational(1, 2), 'a Complex' => Complex(1, 2) }.each do |kind, value|
        it "refuses #{kind}, which is a number and prints as something else" do
          expect { described_class.stringify_query(ids: [value]) }
            .to raise_error(ArgumentError, /\Aquery parameter ids\[0\] was given as #{value.class}, .+ a number of another kind as an Integer or a Float/)
        end
      end

      [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
        it "refuses #{value}, which is a Float and no number a query string spells" do
          expect { described_class.stringify_query(condition: { weight: value }) }
            .to raise_error(ArgumentError, /\Aquery parameter condition\[weight\] is #{value}, and a query string has no spelling for a Float that is not finite/)
        end
      end

      it 'still writes a Float of any size' do
        expect(described_class.stringify_query(a: 0.0, b: -2.5, c: 1e20)).to eq({ 'a' => '0.0', 'b' => '-2.5', 'c' => '1.0e+20' })
      end
    end

    # `ActionController::Parameters` is not a Hash. Nested, it was written
    # as its `to_s`; as the whole query it raised NoMethodError.
    context 'with what converts to a Hash and is not one' do
      it 'reads it as that Hash where it is a value' do
        expect(described_class.stringify_query(condition: StrongParameters.new(open: StrongParameters.new(limit: 5))))
          .to eq({ 'condition' => { 'open' => { 'limit' => '5' } } })
      end

      it 'reads it as that Hash where it is the query' do
        expect(described_class.stringify_query(StrongParameters.new(page: 2))).to eq({ 'page' => '2' })
      end

      it 'refuses two spellings of one key in it, as in a Hash' do
        expect { described_class.stringify_query(condition: StrongParameters.new(a: 1), 'condition' => 2) }.to raise_error(ArgumentError, /given twice/)
      end

      it 'sends it the way Rails reads a nested parameter back' do
        stub = stub_request(:get, "#{url}/search").with(query: { 'condition' => { 'state' => { 'operator' => 'is' } } }).to_return(json_response([]))
        unit_transport.get('api/v1/groups/search', operation: 'test', query: { condition: StrongParameters.new(state: { operator: 'is' }) })

        expect(stub).to have_been_requested
      end
    end

    it 'refuses a query that is no Hash, naming its class' do
      expect { described_class.stringify_query('page=2') }
        .to raise_error(ArgumentError, 'query needs to be a Hash of parameter names and values, got String')
    end

    # Faraday's escaping raised Encoding::CompatibilityError for one.
    it 'sends a value given in UTF-16 as the same text in UTF-8' do
      stub = stub_request(:get, "#{url}/search").with(query: { 'query' => 'ä b' }).to_return(json_response([]))
      unit_transport.get('api/v1/groups/search', operation: 'test', query: { query: 'ä b'.encode('UTF-16LE') })
      expect(stub).to have_been_requested
    end

    it 'leaves a value in an encoding ASCII is a part of as it was' do
      value = "caf\xC3\xA9".b

      expect(described_class.stringify_query(q: value)['q']).to be(value)
    end

    it 'refuses a value that cannot be converted to UTF-8, without quoting it' do
      broken = "\xD8\x00".dup.force_encoding('UTF-16BE')

      expect { described_class.stringify_query(token: broken) }
        .to raise_error(ArgumentError, /\Aquery parameter token was given as UTF-16BE text that cannot be converted to UTF-8/)
    end

    it 'raises on a nil value rather than dropping the parameter' do
      expect { unit_transport.get('api/v1/groups', operation: 'test', query: { page: 1, note: nil }) }
        .to raise_error(ArgumentError, /query parameter note is nil/)
    end

    it 'names the path to a nil buried in a nested value' do
      expect { described_class.stringify_query(condition: { state: { value: nil } }) }
        .to raise_error(ArgumentError, /parameter condition\[state\]\[value\] is nil/)
    end

    it 'refuses two spellings of one parameter rather than sending whichever came last' do
      expect { described_class.stringify_query(state_id: 1, 'state_id' => 2) }
        .to raise_error(ArgumentError, /parameter state_id was given twice/)
    end

    it 'refuses the collision whichever order it arrives in' do
      expect { described_class.stringify_query('state_id' => 2, state_id: 1) }
        .to raise_error(ArgumentError, /parameter state_id was given twice/)
    end

    it 'names both spellings, so the caller does not have to guess the other' do
      expect { described_class.stringify_query(state_id: 1, 'state_id' => 2) }
        .to raise_error(ArgumentError, /as :state_id and as "state_id"/)
    end

    # `condition` is a Hash the search endpoints read, and two spellings inside
    # it collapsed exactly the way two at the top level did.
    it 'refuses a collision nested inside a structured parameter' do
      expect { described_class.stringify_query(condition: { 'state_id' => 1, state_id: 2 }) }
        .to raise_error(ArgumentError, /parameter condition\[state_id\] was given twice/)
    end

    it 'still sends a structured parameter whose keys only look alike' do
      expect(described_class.stringify_query(condition: { 'ticket.state_id' => { operator: 'is' } }))
        .to eq({ 'condition' => { 'ticket.state_id' => { 'operator' => 'is' } } })
    end

    it 'still accepts two parameters that only look alike' do
      expect(described_class.stringify_query(state_id: 1, state_ids: [2]))
        .to eq({ 'state_id' => '1', 'state_ids' => ['2'] })
    end

    it 'names the index of a nil inside an array' do
      expect { described_class.stringify_query(ids: [1, nil]) }
        .to raise_error(ArgumentError, /query parameter ids\[1\] is nil/)
    end

    it 'makes no request for a query it rejects' do
      stub = stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

      expect { unit_transport.get('api/v1/groups', operation: 'test', query: { note: nil }) }
        .to raise_error(ArgumentError)
      expect(stub).not_to have_been_requested
    end

    # A query string does not mark where an element of a list ends. Rails
    # begins a new one where a pair names a place the element it is filling
    # has taken already, so a list is refused where it would not be read
    # back as the list it was: the request would carry something the caller
    # did not write, to an endpoint that narrows by it.
    describe 'a list a query string cannot carry' do
      it 'refuses a Hash that shares no key with the one before it, which Rails would read into it' do
        expect { described_class.stringify_query(condition: { conditions: [{ a: 1 }, { b: 2 }] }) }
          .to raise_error(ArgumentError, /query parameter condition\[conditions\]\[1\] has no plain value under a key the element before it has as well/)
      end

      it 'refuses one that shares a key holding only a list' do
        expect { described_class.stringify_query(list: [{ value: [1] }, { value: [2] }]) }
          .to raise_error(ArgumentError, /Rails would read the two as one/)
      end

      it 'refuses a Hash with nothing in it, which is not written at all' do
        expect { described_class.stringify_query(list: [{ a: 1 }, {}]) }
          .to raise_error(ArgumentError, /query parameter list\[1\] is a Hash with no value in it.*one element short/)
      end

      it 'refuses a list directly inside a list' do
        expect { described_class.stringify_query(list: [[1, 2], [3]]) }
          .to raise_error(ArgumentError, /query parameter list\[0\] is a list directly inside a list/)
      end

      it 'says where such a structure can be sent as it is' do
        expect { described_class.stringify_query(list: [{ a: 1 }, { b: 2 }]) }
          .to raise_error(ArgumentError, /put it in the JSON body of a raw request, such as client\.post/)
      end

      it 'takes a group of conditions beside a condition, which share an operator' do
        conditions = [{ name: 'ticket.state_id', operator: 'is', value: [2] }, { operator: 'AND', conditions: [{ name: 'a', operator: 'is', value: 1 }] }]

        expect(described_class.stringify_query(condition: { operator: 'OR', conditions: conditions }).dig('condition', 'conditions', 1, 'operator')).to eq('AND')
      end

      it 'takes Hashes among plain values, each of which begins an element of its own' do
        expect(described_class.stringify_query(list: [{ a: 1 }, 2, { b: 3 }])).to eq('list' => [{ 'a' => '1' }, '2', { 'b' => '3' }])
      end

      it 'makes no request for one' do
        stub = stub_request(:get, url).with(query: hash_including({})).to_return(json_response([]))

        expect { unit_transport.get('api/v1/groups', operation: 'test', query: { list: [{ a: 1 }, { b: 2 }] }) }.to raise_error(ArgumentError)
        expect(stub).not_to have_been_requested
      end
    end

    # A query string has no way to write a key with an empty name: `[]`
    # inside a structure, which Rails reads as a list, and nothing but the
    # value at the top level, which Rails drops.
    describe 'a key with an empty name' do
      it 'refuses one in a Hash inside a list, which Rails would read as a list' do
        expect { described_class.stringify_query(list: [{ '' => '1' }]) }
          .to raise_error(ArgumentError, /query parameter list\[0\] holds a key with an empty name.*list\[0\]\[\], which Rails reads as a list/)
      end

      it 'refuses one in a Hash further down' do
        expect { described_class.stringify_query(condition: { a: { '' => '1' } }) }
          .to raise_error(ArgumentError, /query parameter condition\[a\] holds a key with an empty name/)
      end

      it 'refuses one given as an empty Symbol' do
        expect { described_class.stringify_query(condition: { '': '1' }) }.to raise_error(ArgumentError, /holds a key with an empty name/)
      end

      it 'refuses one at the top level, which Rails drops' do
        expect { described_class.stringify_query('' => '1') }.to raise_error(ArgumentError, /a query parameter has an empty name.*which Rails drops/)
      end

      it 'still takes a Hash in a list with an ordinary key' do
        expect(described_class.stringify_query(list: [{ 'a' => '1' }])).to eq('list' => [{ 'a' => '1' }])
      end

      it 'still takes a key that is a space' do
        expect(described_class.stringify_query(condition: { ' ' => '1' })).to eq('condition' => { ' ' => '1' })
      end
    end

    # Read off the URL Faraday built, in the order it was written: WebMock
    # sorts a query before it compares one, and the order is the point. See
    # the QueryEncoder specs for why this is the order Rails needs.
    it 'writes the query with the encoder that keeps a list of Hashes apart' do
      sent     = nil
      recorder = Class.new(Faraday::Middleware) do
        define_method(:on_request) { |env| sent = URI.decode_www_form(env.url.query).map(&:first) }
      end
      stub_request(:get, "#{url}/search").with(query: hash_including({})).to_return(json_response([]))

      unit_transport(middleware: ->(builder) { builder.use(recorder) }).get(
        'api/v1/groups/search',
        operation: 'test',
        query:     { condition: { conditions: [{ name: 'a', operator: 'is', value: 1 }, { operator: 'AND', conditions: [{ name: 'b', operator: 'is', value: 2 }] }] } }
      )

      expect(sent.drop(3).first(2)).to eq(['condition[conditions][][operator]', 'condition[conditions][][conditions][][name]'])
    end
  end

  # The path is printed in the log, in the message of a timeout and in the
  # operation a raw request is named by, and a raw request may carry its
  # query in it.
  describe '.redact_path' do
    it 'leaves a path without a query as it is' do
      expect(described_class.redact_path('api/v1/tickets/1')).to eq('api/v1/tickets/1')
    end

    it 'blanks the value of a parameter named like a credential' do
      expect(described_class.redact_path('api/v1/x?token=s3cret')).to eq('api/v1/x?token=[REDACTED]')
    end

    it 'keeps every other parameter as it was written' do
      expect(described_class.redact_path('api/v1/x?page=2&password=s3cret&q=a%20b')).to eq('api/v1/x?page=2&password=[REDACTED]&q=a%20b')
    end

    it 'reads a name that was percent-encoded' do
      expect(described_class.redact_path('api/v1/x?user%5Bpassword%5D=s3cret')).to eq('api/v1/x?user%5Bpassword%5D=[REDACTED]')
    end

    it 'blanks a value whose name cannot be read' do
      expect(described_class.redact_path('api/v1/x?%zz=s3cret')).to eq('api/v1/x?%zz=[REDACTED]')
    end

    it 'keeps a parameter with no value' do
      expect(described_class.redact_path('api/v1/x?expand&token=s3cret')).to eq('api/v1/x?expand&token=[REDACTED]')
    end

    it 'blanks a value that holds a = of its own' do
      expect(described_class.redact_path('api/v1/x?token=a=b')).to eq('api/v1/x?token=[REDACTED]')
    end

    # Rack 2 ends a parameter at a `;` as it does at an `&`, and Zammad ran
    # on it up to 7.0. There `?page=2;token=s3cret` carries a token, and
    # split at `&` alone it was the tail of a value named `page`.
    context 'with parameters separated by a semicolon' do
      it 'blanks the value of one named like a credential' do
        expect(described_class.redact_path('api/v1/x?page=2;token=s3cret')).to eq('api/v1/x?page=2;token=[REDACTED]')
      end

      it 'keeps the parameters around it as they were written' do
        expect(described_class.redact_path('api/v1/x?page=2;token=s3cret;q=a%20b&locale=de')).to eq('api/v1/x?page=2;token=[REDACTED];q=a%20b&locale=de')
      end

      it 'reads the name behind a parameter with no value' do
        expect(described_class.redact_path('api/v1/x?expand;page=2;password=s3cret')).to eq('api/v1/x?expand;page=2;password=[REDACTED]')
      end

      it 'reads a name behind the space Rack skips after a separator' do
        expect(described_class.redact_path('api/v1/x?page=2; token=s3cret')).to eq('api/v1/x?page=2; token=[REDACTED]')
      end

      it 'blanks a value whose name cannot be read' do
        expect(described_class.redact_path('api/v1/x?page=2;%zz=s3cret')).to eq('api/v1/x?page=2;%zz=[REDACTED]')
      end

      # Rack 3 reads a `;` as part of the value, and so does every Zammad
      # since 7.1. A credential is blanked to the next `&`, so that neither
      # reading leaves the rest of it standing.
      it 'blanks a credential that holds one to the end of its value' do
        expect(described_class.redact_path('api/v1/x?token=s3;cret&page=2')).to eq('api/v1/x?token=[REDACTED]&page=2')
      end

      it 'leaves a query without a credential as it was written' do
        expect(described_class.redact_path('api/v1/x?page=2;q=a;b&c;')).to eq('api/v1/x?page=2;q=a;b&c;')
      end
    end
  end

  # The question the test kit asks, so that it sends again what the wire
  # sends again.
  describe '.retried?' do
    let(:config) { ZammadAPI::Config.new(**unit_config(retries: 2, timeout: 60)) }

    def response(status, headers = {})
      ZammadAPI::Response.new(status: status, headers: headers, body: nil, raw_body: '', json: false)
    end

    described_class::RETRIABLE_STATUSES.each do |status|
      it "is true for a GET answered #{status}" do
        expect(described_class.retried?(config, :get, response(status))).to be(true)
      end
    end

    [200, 404, 422].each do |status|
      it "is false for a GET answered #{status}" do
        expect(described_class.retried?(config, :get, response(status))).to be(false)
      end
    end

    %i[post put delete].each do |verb|
      it "is false for a #{verb.to_s.upcase}, which is never sent twice" do
        expect(described_class.retried?(config, verb, response(503))).to be(false)
      end
    end

    it 'is false where Retry-After asks for longer than the timeout' do
      expect(described_class.retried?(config, :get, response(429, 'retry-after' => '61'))).to be(false)
    end

    it 'is true where Retry-After asks for no longer than the timeout' do
      expect(described_class.retried?(config, :get, response(429, 'retry-after' => '60'))).to be(true)
    end

    it 'reads a Retry-After that is a date' do
      expect(described_class.retried?(config, :get, response(503, 'retry-after' => (Time.now + 3600).utc.strftime('%a, %d %b %Y %H:%M:%S GMT')))).to be(false)
    end

    it 'reads a RateLimit-Reset the same way' do
      expect(described_class.retried?(config, :get, response(429, 'ratelimit-reset' => '3600'))).to be(false)
    end

    # What makes this the transport's own answer and not a second reading of
    # the same rules: a stack that was answered this way made one request.
    it 'agrees with what a request does' do
      stub_request(:get, url).to_return({ status: 429, headers: { 'Retry-After' => '3600' } }, json_response([]))
      transport = unit_transport(retries: 2, retry_interval: 0.01, timeout: 2)

      expect { transport.get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::RateLimitError) do |error|
        expect(described_class.retried?(transport.config, :get, error.response)).to be(false)
      end
      expect(a_request(:get, url)).to have_been_made.once
    end
  end

  describe '.redact' do
    it 'blanks the value under a key that names a credential' do
      expect(described_class.redact({ login: 'x', password: 'hunter2' })).to eq({ login: 'x', password: '[REDACTED]' })
    end

    it 'reads a String key the way it reads a Symbol' do
      expect(described_class.redact({ 'api_key' => 'k' })).to eq({ 'api_key' => '[REDACTED]' })
    end

    it 'blanks one at any depth, through Hashes and Arrays' do
      expect(described_class.redact({ users: [{ preferences: { access_token: 't', locale: 'de' } }] }))
        .to eq({ users: [{ preferences: { access_token: '[REDACTED]', locale: 'de' } }] })
    end

    it 'blanks the whole of a structure held under such a key' do
      expect(described_class.redact({ tokens: [{ name: 'a' }] })).to eq({ tokens: '[REDACTED]' })
    end

    it 'leaves what it was given as it was' do
      attributes = { password: 'hunter2' }
      described_class.redact(attributes)

      expect(attributes).to eq({ password: 'hunter2' })
    end

    it 'hands back anything that is not a structure' do
      expect(described_class.redact('password')).to eq('password')
    end
  end

  describe '.escape_path_segment' do
    it 'leaves an ordinary id alone' do
      expect(described_class.escape_path_segment(42)).to eq('42')
    end

    it 'encodes a separator, so an id cannot walk out of its segment' do
      expect(described_class.escape_path_segment('1/../../api/v1/users/1'))
        .to eq('1%2F..%2F..%2Fapi%2Fv1%2Fusers%2F1')
    end

    it 'encodes a query and fragment marker' do
      expect(described_class.escape_path_segment('1?a=b#c')).to eq('1%3Fa%3Db%23c')
    end

    it 'encodes a multibyte character one byte at a time' do
      expect(described_class.escape_path_segment('ä')).to eq('%C3%A4')
    end

    it 'raises for an id with nothing to send' do
      expect { described_class.escape_path_segment('') }.to raise_error(ArgumentError, /record id is required/)
    end

    it 'raises for a parent dot segment, which the unreserved set would carry through' do
      expect { described_class.escape_path_segment('..') }.to raise_error(ArgumentError, /points at another endpoint/)
    end

    it 'raises for a current-directory dot segment' do
      expect { described_class.escape_path_segment('.') }.to raise_error(ArgumentError, /points at another endpoint/)
    end

    it 'leaves an id that merely starts with dots alone' do
      expect(described_class.escape_path_segment('..1')).to eq('..1')
    end

    it 'encodes an already-encoded dot segment rather than passing it on' do
      expect(described_class.escape_path_segment('%2e%2e')).to eq('%252e%252e')
    end

    it 'takes a Symbol, for a member that is named rather than numbered' do
      expect(described_class.escape_path_segment(:me)).to eq('me')
    end

    # `to_s` answers for every object, so a record where its id belongs was
    # pasted into the path as it inspects and answered with a 404.
    it 'raises for a record where its id belongs' do
      record = ZammadAPI::Resources::Group.from_response(unit_transport, { id: 1, name: 'Users' })

      expect { described_class.escape_path_segment(record) }
        .to raise_error(ArgumentError, /record id is an Integer or a String, and this one is ZammadAPI::Resources::Group/)
    end

    it 'does not quote what it refuses, which for a record is its attributes' do
      record = ZammadAPI::Resources::Group.from_response(unit_transport, { id: 1, name: 'Users' })

      expect { described_class.escape_path_segment(record) }.to raise_error(ArgumentError) { |error| expect(error.message).not_to include('Users') }
    end

    [[1], { id: 1 }, 1.0, true, Object.new].each do |value|
      it "raises for #{value.class}, which only prints as something" do
        expect { described_class.escape_path_segment(value) }.to raise_error(ArgumentError, /this one is #{value.class}/)
      end
    end

    it 'still says that an id is missing for nil' do
      expect { described_class.escape_path_segment(nil) }.to raise_error(ArgumentError, /record id is required/)
    end
  end

  describe 'request bodies' do
    it 'sends JSON with the matching content type' do
      stub = stub_request(:post, url)
        .with(body: '{"name":"Support"}', headers: { 'Content-Type' => 'application/json' })
        .to_return(json_response({ id: 1 }, status: 201))
      unit_transport.post('api/v1/groups', operation: 'test', body: { name: 'Support' })
      expect(stub).to have_been_requested
    end

    it 'sends a body that is already a string as it is' do
      stub = stub_request(:post, url)
        .with(body: '{"name":"Raw"}', headers: { 'Content-Type' => 'application/json' })
        .to_return(json_response({ id: 1 }, status: 201))
      unit_transport.post('api/v1/groups', operation: 'test', body: '{"name":"Raw"}')
      expect(stub).to have_been_requested
    end

    # The generator has no spelling for `ActionController::Parameters` and
    # writes its `to_s`, so the body was one JSON string holding a Ruby
    # inspect of the parameters.
    context 'with a body that converts to a Hash and is not one' do
      before { stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201)) }

      it 'sends it as the JSON object it converts to' do
        unit_transport.post('api/v1/groups', operation: 'test', body: StrongParameters.new(name: 'Support', preferences: StrongParameters.new(locale: 'de')))

        expect(a_request(:post, url).with(body: '{"name":"Support","preferences":{"locale":"de"}}')).to have_been_made
      end

      it 'sends one that a Hash or an Array holds the same way' do
        unit_transport.post('api/v1/groups', operation: 'test', body: { groups: [StrongParameters.new(name: 'Support')] })

        expect(a_request(:post, url).with(body: '{"groups":[{"name":"Support"}]}')).to have_been_made
      end

      it 'sends nothing where it refuses to convert' do
        expect { unit_transport.post('api/v1/groups', operation: 'test', body: StrongParameters.new({ name: 'Support' }, permitted: false)) }
          .to raise_error(StrongParameters::Unfiltered)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end
    end

    # The generator writes an object JSON has no type for as its `to_s`, so
    # `role_ids: Set[1, 2]` went out as the String "Set[1, 2]" where the
    # list belongs, and nothing raised.
    context 'with a value JSON has no type for' do
      let(:url) { "#{ClientHelper::BASE_URL}api/v1/users" }

      before { stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201)) }

      { 'a Set' => Set[1, 2], 'a Range' => (1..3), 'a Struct' => Struct.new(:id).new(1), 'a Rational' => Rational(1, 2), 'any other object' => Object.new }.each do |kind, value|
        it "raises a ZammadAPI::Error for #{kind}, which only prints as something" do
          expect { unit_transport.post('api/v1/users', operation: 'save object', body: { role_ids: value }) }
            .to raise_error(ZammadAPI::Error, /request body cannot be encoded as JSON \(its key role_ids was given as #{Regexp.escape(value.class.to_s)}, which is no JSON type/)
        end
      end

      it 'raises for one further in' do
        expect { unit_transport.post('api/v1/users', operation: 'save object', body: { users: [{ role_ids: Set[1] }] }) }
          .to raise_error(ZammadAPI::Error, /its key role_ids was given as Set/)
      end

      it 'raises for one that is the whole body' do
        expect { unit_transport.post('api/v1/users', operation: 'save object', body: Set[1]) }
          .to raise_error(ZammadAPI::Error, /\(it was given as Set/)
      end

      it 'says what to pass in its place' do
        expect { unit_transport.post('api/v1/users', operation: 'save object', body: { role_ids: Set[1, 2] }) }
          .to raise_error(ZammadAPI::Error, /pass a Set or a Range as its to_a/)
      end

      it 'does not quote what it refuses' do
        holder = Class.new { def initialize = @password = 'object-s3cret' }.new

        expect { unit_transport.post('api/v1/users', operation: 'save object', body: { user: holder }) }
          .to raise_error(ZammadAPI::Error) { |error| expect(error.message).not_to include('object-s3cret') }
      end

      it 'makes no request' do
        expect { unit_transport.post('api/v1/users', operation: 'save object', body: { role_ids: Set[1, 2] }) }.to raise_error(ZammadAPI::Error)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'is raised by a record save carrying such a value' do
        user = unit_client.users.new(login: 'jane', role_ids: Set[1, 2])
        expect { user.save }.to raise_error(ZammadAPI::Error, /its key role_ids was given as Set/)
      end

      it 'sends a Symbol as text, as the generator writes it' do
        unit_transport.post('api/v1/users', operation: 'test', body: { state: :open, 1 => nil })

        expect(a_request(:post, url).with(body: '{"state":"open","1":null}')).to have_been_made
      end

      # Zammad reads a time or a date attribute from the text either prints.
      it 'sends a Time and a Date as they print' do
        unit_transport.post('api/v1/users', operation: 'test', body: { pending_time: Time.utc(2026, 1, 2, 3, 4, 5), due: Date.new(2026, 1, 2) })

        expect(a_request(:post, url).with(body: '{"pending_time":"2026-01-02 03:04:05 UTC","due":"2026-01-02"}')).to have_been_made
      end

      # A member called `method` is in the way of asking the object where
      # its `to_json` comes from, and is not asked.
      it 'leaves an object with a to_json of its own to write itself' do
        # rubocop:disable-next Lint/DataDefineOverride -- the member in the way is the point
        point = Data.define(:method, :id) { def to_json(*) = to_h.to_json(*) }.new('get', 1)
        unit_transport.post('api/v1/users', operation: 'test', body: { point: point, points: [point] })

        expect(a_request(:post, url).with(body: '{"point":{"method":"get","id":1},"points":[{"method":"get","id":1}]}')).to have_been_made
      end

      it 'sends a record of this gem as its attributes' do
        group = ZammadAPI::Resources::Group.from_response(unit_transport, { id: 1, name: 'Users' })
        unit_transport.post('api/v1/users', operation: 'test', body: { group: group })

        expect(a_request(:post, url).with(body: '{"group":{"id":1,"name":"Users"}}')).to have_been_made
      end
    end

    # ActiveSupport gives every object an `as_json` and builds `to_json` on
    # it, which is what 1.x sent a body with. `JSON.generate` does not ask
    # it, so in a Rails app a Set was the list under 1.x and its `to_s`
    # here, and `2.days` was "172800". Stood in for by objects that define
    # the method, as ActiveSupport is not loaded here.
    context 'with an object that says what it is as JSON' do
      let(:as_json_class) { Struct.new(:described) { def as_json(*) = described } }

      before { stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201)) }

      it 'sends what its as_json returns' do
        unit_transport.post('api/v1/groups', operation: 'test', body: { ids: as_json_class.new([1, 2]), ttl: as_json_class.new(172_800) })

        expect(a_request(:post, url).with(body: '{"ids":[1,2],"ttl":172800}')).to have_been_made
      end

      it 'sends one that is the whole body the same way' do
        unit_transport.post('api/v1/groups', operation: 'test', body: as_json_class.new({ 'name' => 'Support' }))

        expect(a_request(:post, url).with(body: '{"name":"Support"}')).to have_been_made
      end

      it 'asks what its as_json returns in turn' do
        unit_transport.post('api/v1/groups', operation: 'test', body: { group: as_json_class.new({ 'ids' => as_json_class.new([1]) }) })

        expect(a_request(:post, url).with(body: '{"group":{"ids":[1]}}')).to have_been_made
      end

      it 'raises where its as_json is no JSON type either' do
        number = as_json_class.new(Rational(1, 2))

        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: { weight: number }) }
          .to raise_error(ZammadAPI::Error, /its key weight was given as #{Regexp.escape(number.class.to_s)}, which is no JSON type/)
      end

      it 'prefers the to_json an object has of its own' do
        both = Class.new do
          def as_json(*) = { 'from' => 'as_json' }
          def to_json(*) = '{"from":"to_json"}'
        end

        unit_transport.post('api/v1/groups', operation: 'test', body: { value: both.new })

        expect(a_request(:post, url).with(body: '{"value":{"from":"to_json"}}')).to have_been_made
      end
    end

    # Faraday's JSON middleware raised JSON::GeneratorError from inside the
    # stack and nothing mapped it, so it went past the rescue of
    # ZammadAPI::Error every caller is told to write.
    context 'with a body that cannot be encoded as JSON' do
      let(:binary) { { data: "\xFF\xD8\xFF".b } }

      it 'raises a ZammadAPI::Error for bytes that are not text' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary) }
          .to raise_error(ZammadAPI::Error, /Can't save object: the request body cannot be encoded as JSON/)
      end

      it 'raises a ZammadAPI::Error for a Float that JSON has no spelling for' do
        expect { unit_transport.put('api/v1/groups/1', operation: 'save object', body: { weight: Float::NAN }) }
          .to raise_error(ZammadAPI::Error, /NaN not allowed in JSON/)
      end

      it 'says what to do about binary data' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary) }
          .to raise_error(ZammadAPI::Error, /Base64-encode binary data/)
      end

      it 'names the resource it was sending' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary, resource_class: ZammadAPI::Resources::Group) }
          .to raise_error(ZammadAPI::Error, /save object \(ZammadAPI::Resources::Group\)/)
      end

      it 'makes no request' do
        expect { unit_transport.post('api/v1/groups', operation: 'save object', body: binary) }.to raise_error(ZammadAPI::Error)
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'leaves no log line claiming a request that was never made' do
        log = StringIO.new
        expect { unit_transport(logger: Logger.new(log)).post('api/v1/groups', operation: 'save object', body: binary) }
          .to raise_error(ZammadAPI::Error)
        expect(log.string).to be_empty
      end

      it 'is raised by a record save carrying such a value' do
        group = unit_client.groups.new(name: 'Support', weight: Float::INFINITY)
        expect { group.save }.to raise_error(ZammadAPI::Error, /Infinity not allowed in JSON/)
      end
    end
  end

  describe 'response decoding' do
    it 'decodes JSON with symbol keys' do
      stub_request(:get, url).to_return(json_response({ id: 1, nested: { a: 'b' } }))
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq({ id: 1, nested: { a: 'b' } })
    end

    it 'exposes the raw body as well' do
      stub_request(:get, url).to_return(json_response({ id: 1 }))
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.raw_body).to eq('{"id":1}')
    end

    it 'leaves non-JSON bodies untouched' do
      stub_request(:get, url).to_return(status: 200, body: 'plain text', headers: { 'Content-Type' => 'text/plain' })
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq('plain text')
    end

    it 'keeps a malformed JSON body as a string instead of raising' do
      stub_request(:get, url).to_return(status: 200, body: 'not json', headers: { 'Content-Type' => 'application/json' })
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq('not json')
    end

    it 'handles an empty body' do
      stub_request(:get, url).to_return(status: 200, body: '', headers: { 'Content-Type' => 'application/json' })
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.body).to eq('')
    end

    it 'downcases header names' do
      stub_request(:get, url).to_return(json_response([], headers: { 'X-Request-Id' => 'abc' }))
      response = unit_transport.get('api/v1/groups', operation: 'test')
      expect(response.headers['x-request-id']).to eq('abc')
    end
  end

  describe 'error responses' do
    it 'raises NotFoundError for 404' do
      stub_request(:get, url).to_return(json_response({ error: 'nope' }, status: 404))
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::NotFoundError, "Can't find object: nope")
    end

    it 'raises AuthenticationError for 401' do
      stub_request(:get, url).to_return(json_response({ error: 'authentication failed' }, status: 401))
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::AuthenticationError)
    end

    it 'raises ServerError with the status when a proxy returns HTML' do
      stub_request(:get, url).to_return(status: 502, body: '<html>Bad Gateway</html>', headers: { 'Content-Type' => 'text/html' })
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::ServerError, "Can't find object: HTTP 502")
    end

    it 'includes the resource class in the message' do
      stub_request(:get, url).to_return(json_response({ error: 'nope' }, status: 404))
      expect { unit_transport.get('api/v1/groups', operation: 'find object', resource_class: ZammadAPI::Resources::Group) }
        .to raise_error(/\(ZammadAPI::Resources::Group\)/)
    end
  end

  describe 'network failures' do
    it 'wraps a read timeout' do
      stub_request(:get, url).to_raise(Net::ReadTimeout)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError, %r{Can't find object: request to api/v1/groups timed out})
    end

    it 'keeps a credential in a query written into the path out of the message' do
      stub_request(:get, url).with(query: hash_including({})).to_raise(Net::ReadTimeout)
      expect { unit_transport.get('api/v1/groups?token=path-s3cret', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError, %r{request to api/v1/groups\?token=\[REDACTED\] timed out})
    end

    # Net::HTTP reads a body framed by Content-Length until the count is
    # reached or the connection ends, and takes the second for the first.
    # The bytes that had arrived came back as the response.
    context 'when the connection closes before the body has arrived' do
      def cut_off(headers = {}, status: 200, body: '0123456789')
        stub_request(:get, url).to_return(status: status, body: body, headers: { 'Content-Length' => '1000' }.merge(headers))
      end

      it 'raises a ConnectionError for a body shorter than its Content-Length' do
        cut_off({ 'Content-Type' => 'image/png' })

        expect { unit_transport.get('api/v1/groups', operation: 'download attachment') }
          .to raise_error(ZammadAPI::ConnectionError, %r{\ACan't download attachment: the response from http://zammad\.test/ ended 990 bytes short of the 1000})
      end

      it 'raises for a JSON body that is short, and still parses' do
        cut_off({ 'Content-Type' => 'application/json' }, body: '[]')

        expect { unit_transport.get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::ConnectionError, /998 bytes short/)
      end

      it 'raises for a body of which nothing arrived' do
        cut_off(body: '')

        expect { unit_transport.get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::ConnectionError, /1000 bytes short/)
      end

      it 'counts the bytes, not the characters' do
        stub_request(:get, url).to_return(status: 200, body: 'ää', headers: { 'Content-Length' => '4', 'Content-Type' => 'text/plain; charset=utf-8' })

        expect(unit_transport.get('api/v1/groups', operation: 'test').raw_body.bytesize).to eq(4)
      end

      it 'returns a body as long as its Content-Length' do
        stub_request(:get, url).to_return(status: 200, body: '0123456789', headers: { 'Content-Length' => '10' })

        expect(unit_transport.get('api/v1/groups', operation: 'test').raw_body).to eq('0123456789')
      end

      it 'returns a body that names no Content-Length' do
        stub_request(:get, url).to_return(status: 200, body: '0123456789')

        expect(unit_transport.get('api/v1/groups', operation: 'test').raw_body).to eq('0123456789')
      end

      # The bytes in hand may be the decoded ones, beside a count of the
      # encoded ones, and a chunked body is not framed by the count.
      it 'does not judge a body under a Content-Encoding or a Transfer-Encoding' do
        [{ 'Content-Encoding' => 'br' }, { 'Transfer-Encoding' => 'chunked' }].each do |header|
          cut_off(header)

          expect(unit_transport.get('api/v1/groups', operation: 'test').raw_body).to eq('0123456789')
        end
      end

      it 'does not judge a Content-Length that is not one figure' do
        ['1000, 1000', 'many', ''].each do |announced|
          cut_off({ 'Content-Length' => announced })

          expect(unit_transport.get('api/v1/groups', operation: 'test').raw_body).to eq('0123456789')
        end
      end

      it 'does not judge a 204, which has no body whatever is announced beside it' do
        stub_request(:delete, url).to_return(status: 204, body: '', headers: { 'Content-Length' => '5' })

        expect(unit_transport.delete('api/v1/groups', operation: 'test').status).to eq(204)
      end

      it 'leaves a body that is longer than announced alone' do
        stub_request(:get, url).to_return(status: 200, body: '0123456789', headers: { 'Content-Length' => '4' })

        expect(unit_transport.get('api/v1/groups', operation: 'test').raw_body).to eq('0123456789')
      end

      # The status is what such a response says, and the body is read for
      # the message only.
      it 'still raises the error its status names for one that is not a 2xx' do
        cut_off({ 'Content-Type' => 'application/json' }, status: 404, body: '{"error":')

        expect { unit_transport.get('api/v1/groups', operation: 'find object') }.to raise_error(ZammadAPI::NotFoundError)
      end

      it 'logs the response it then refuses' do
        log = StringIO.new
        cut_off

        expect { unit_transport(logger: Logger.new(log)).get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::ConnectionError)
        expect(log.string).to include('Zammad API response: GET api/v1/groups -> 200')
      end
    end

    # Net::HTTP raises Net::OpenTimeout for it, and the default adapter wraps
    # that into Faraday::ConnectionFailed with every other failure to connect,
    # so it was reported as an unreachable host and skipped the rescue that is
    # documented to catch it.
    context 'when the connection is not established within open_timeout' do
      before { stub_request(:get, url).to_raise(Net::OpenTimeout.new('execution expired')) }

      it 'raises TimeoutError, not ConnectionError' do
        expect { unit_transport.get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError)
      end

      it 'says it was the connection that timed out' do
        expect { unit_transport.get('api/v1/groups', operation: 'find object') }
          .to raise_error(%r{Can't find object: connecting to http://zammad\.test/ timed out \(execution expired\)})
      end

      it 'is still retried, as a read that never reached the server' do
        expect { unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError)
        expect(a_request(:get, url)).to have_been_made.times(3)
      end
    end

    it 'reports the timeout WebMock simulates as one' do
      stub_request(:get, url).to_timeout
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError)
    end

    it 'reads a timeout out of a connection failure that only wraps one' do
      stub_request(:get, url).to_raise(Faraday::ConnectionFailed.new(Errno::ETIMEDOUT.new))
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TimeoutError, /connecting to/)
    end

    it 'wraps a refused connection' do
      stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::ConnectionError, /is unreachable/)
    end

    it 'wraps a TLS failure' do
      stub_request(:get, url).to_raise(OpenSSL::SSL::SSLError)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::ConnectionError, /TLS handshake/)
    end

    it 'names the instance it could not reach' do
      stub_request(:get, url).to_raise(Faraday::ConnectionFailed.new('down'))

      expect { unit_transport.get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError, %r{http://zammad\.test/ is unreachable})
    end

    context 'with an adapter that does not wrap socket errors' do
      # The middleware seam raises from inside the stack, past the point where
      # an adapter would normally translate the error into a Faraday one.
      def raising(error)
        unit_transport(middleware: lambda { |faraday|
          faraday.use(Class.new(Faraday::Middleware) { define_method(:call) { |_env| raise error } })
        })
      end

      it 'wraps a bare Errno::ETIMEDOUT' do
        expect { raising(Errno::ETIMEDOUT).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError, /timed out/)
      end

      it 'wraps a bare Timeout::Error' do
        expect { raising(Timeout::Error).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::TimeoutError)
      end

      it 'wraps a bare Errno::ECONNREFUSED' do
        expect { raising(Errno::ECONNREFUSED).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::ConnectionError, /is unreachable/)
      end

      it 'wraps a SocketError' do
        expect { raising(SocketError).get('api/v1/groups', operation: 'find object') }
          .to raise_error(ZammadAPI::ConnectionError)
      end

      it 'leaves an unrelated Errno alone rather than calling it a network problem' do
        expect { raising(Errno::ENOSPC).get('api/v1/groups', operation: 'find object') }
          .to raise_error(Errno::ENOSPC)
      end
    end

    it 'raises a TransportError subclass so both can be rescued together' do
      stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
      expect { unit_transport.get('api/v1/groups', operation: 'find object') }
        .to raise_error(ZammadAPI::TransportError)
    end
  end

  describe 'retries' do
    it 'retries an idempotent request after a server error' do
      stub_request(:get, url).to_return({ status: 500 }, json_response([{ id: 1 }]))
      response = unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'test')
      expect(response.status).to eq(200)
    end

    it 'retries after a rate limit response' do
      stub_request(:get, url).to_return({ status: 429 }, json_response([]))
      response = unit_transport(retries: 1, retry_interval: 0.01).get('api/v1/groups', operation: 'test')
      expect(response.status).to eq(200)
    end

    # The retry middleware sleeps for whatever Retry-After says, and its own
    # ceiling defaults to none: this held the calling thread for an hour per
    # retry before raising the error it could have raised at once.
    context 'when the server asks for a longer wait than the timeout' do
      let(:transport) { unit_transport(retries: 2, retry_interval: 0.01, timeout: 2) }

      before do
        stub_request(:get, url).to_return({ status: 429, headers: { 'Retry-After' => '3600' } }, json_response([]))
      end

      it 'reports the response instead of waiting it out' do
        expect { transport.get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::RateLimitError)
      end

      it 'does not retry' do
        expect { transport.get('api/v1/groups', operation: 'test') }.to raise_error(ZammadAPI::RateLimitError)
        expect(a_request(:get, url)).to have_been_made.once
      end

      it 'leaves the wait the server asked for readable from the error' do
        expect { transport.get('api/v1/groups', operation: 'test') }
          .to raise_error(ZammadAPI::RateLimitError) { |error| expect(error.retry_after).to eq(3600) }
      end
    end

    it 'does not wait out a long Retry-After on a 503 either' do
      stub_request(:get, url).to_return({ status: 503, headers: { 'Retry-After' => '3600' } }, json_response([]))

      expect { unit_transport(retries: 2, retry_interval: 0.01, timeout: 2).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:get, url)).to have_been_made.once
    end

    it 'still waits as long as the server asks, where that is within the timeout' do
      stub_request(:get, url).to_return({ status: 429, headers: { 'Retry-After' => '0.2' } }, json_response([]))

      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = unit_transport(retries: 1, retry_interval: 0.01).get('api/v1/groups', operation: 'test')

      expect(response.status).to eq(200)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.2
    end

    it 'gives up after the configured number of attempts' do
      stub_request(:get, url).to_return(status: 500)
      expect { unit_transport(retries: 1, retry_interval: 0.01).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:get, url)).to have_been_made.twice
    end

    it 'does not retry POST, which could duplicate records' do
      stub_request(:post, url).to_return(status: 500)
      expect { unit_transport(retries: 2, retry_interval: 0.01).post('api/v1/groups', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:post, url)).to have_been_made.once
    end

    # A ticket update carrying an article creates that article on every
    # delivery, so repeating it sent the article - and its e-mail - twice.
    it 'does not retry PUT, which Zammad does not always handle idempotently' do
      stub_request(:put, "#{url}/1").to_return({ status: 504 }, json_response({ id: 1 }))
      expect { unit_transport(retries: 2, retry_interval: 0.01).put('api/v1/groups/1', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::ServerError)
      expect(a_request(:put, "#{url}/1")).to have_been_made.once
    end

    it 'does not retry PUT after a timeout either' do
      stub_request(:put, "#{url}/1").to_raise(Net::ReadTimeout).then.to_return(json_response({ id: 1 }))
      expect { unit_transport(retries: 2, retry_interval: 0.01).put('api/v1/groups/1', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::TimeoutError)
      expect(a_request(:put, "#{url}/1")).to have_been_made.once
    end

    # Repeated after a lost answer, the second DELETE met a 404 and reported a
    # record that had just been deleted as one that could not be found.
    it 'does not retry DELETE, which would answer a lost success with a 404' do
      stub_request(:delete, "#{url}/1").to_raise(Net::ReadTimeout).then.to_return(json_response({ error: 'gone' }, status: 404))
      expect { unit_transport(retries: 2, retry_interval: 0.01).delete('api/v1/groups/1', operation: 'test') }
        .to raise_error(ZammadAPI::TimeoutError)
      expect(a_request(:delete, "#{url}/1")).to have_been_made.once
    end

    it 'does not retry a client error' do
      stub_request(:get, url).to_return(json_response({ error: 'nope' }, status: 404))
      expect { unit_transport(retries: 2, retry_interval: 0.01).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::NotFoundError)
      expect(a_request(:get, url)).to have_been_made.once
    end
  end

  # Most adapters wrap a socket failure into Faraday::ConnectionFailed, which
  # was retried; the same failure raw was not, so how often a request was
  # retried depended on which adapter the caller picked - through an option
  # this gem offers.
  describe 'retries through an adapter that does not wrap socket errors' do
    before { BareSocketAdapter.attempts = [] }

    def bare_socket_transport(**overrides)
      unit_transport(adapter: :bare_socket, retry_interval: 0.01, **overrides)
    end

    it 'retries an unwrapped socket error as often as a wrapped one' do
      expect { bare_socket_transport(retries: 2).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError)
      expect(BareSocketAdapter.attempts.size).to eq(3)
    end

    it 'still maps it to ConnectionError once the retries are spent' do
      expect { bare_socket_transport(retries: 1).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError, /is unreachable/)
    end

    it 'does not repeat a POST, which could duplicate records' do
      expect { bare_socket_transport(retries: 2).post('api/v1/groups', operation: 'test', body: { a: 1 }) }
        .to raise_error(ZammadAPI::ConnectionError)
      expect(BareSocketAdapter.attempts).to eq([:post])
    end

    it 'retries every socket failure it maps to ConnectionError' do
      expect(described_class::RETRIABLE_EXCEPTIONS).to include(*described_class::CONNECTION_ERRORS)
    end

    it 'retries every socket failure it maps to TimeoutError' do
      expect(described_class::RETRIABLE_EXCEPTIONS).to include(*described_class::TIMEOUT_ERRORS)
    end
  end

  describe 'the Faraday seam' do
    it 'calls the middleware with the connection being built' do
      seen = nil
      unit_transport(middleware: ->(connection) { seen = connection })

      expect(seen).to be_a(Faraday::Connection)
    end

    it 'lets the middleware see a request this gem built' do
      stub_request(:get, url).to_return(json_response([]))

      seen = nil
      transport = unit_transport(middleware: lambda { |builder|
        builder.use(Class.new(Faraday::Middleware) do
          define_method(:on_request) { |env| seen = env.request_headers['User-Agent'] }
        end)
      })
      transport.get('api/v1/groups', operation: 'test')

      expect(seen).to eq("zammad_api-ruby/#{ZammadAPI::VERSION}")
    end

    it 'lets the middleware see the response' do
      stub_request(:get, url).to_return(json_response([{ id: 1 }]))

      seen = nil
      transport = unit_transport(middleware: lambda { |builder|
        builder.use(Class.new(Faraday::Middleware) do
          define_method(:on_complete) { |env| seen = env.status }
        end)
      })
      transport.get('api/v1/groups', operation: 'test')

      expect(seen).to eq(200)
    end

    # `c.response :json` is a reasonable thing to put through a documented
    # seam, and Faraday then hands over a Hash rather than the bytes. `to_s`
    # turned that into a Ruby inspect string, which JSON.parse refused, so
    # every record built from the response died in Response#decoded with a
    # ParseError naming Zammad for what the caller's own stack had done.
    #
    # Re-encoding the parsed structure was the other way out, and it is worse:
    # `raw_body` is what an attachment download hands back as the file, so a
    # re-encoding returns something Zammad never stored. The bytes are gone
    # either way, so this names the cause while it is still visible.
    context 'with middleware that decodes the body first' do
      it 'refuses it when the stack is built, before anything is sent' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /decodes the response body before this gem can/)
      end

      it 'names the middleware it found' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /Faraday::Response::Json/)
      end

      it 'says which middleware to drop' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /c\.response :json/)
      end

      it 'is catchable as the gem error every caller rescues' do
        expect { unit_transport(middleware: ->(builder) { builder.response(:json) }) }.to raise_error(ZammadAPI::Error)
      end

      # The check used to live in `decode`, which is one request too late: the
      # POST went out, Zammad created the record, and only then did a
      # "configuration" error come back - so a caller retrying it made a second.
      it 'sends nothing before refusing' do
        stub = stub_request(:post, url).with(query: hash_including({}))

        expect { unit_client(middleware: ->(builder) { builder.response(:json) }).groups.create(name: 'X') }
          .to raise_error(ZammadAPI::ConfigurationError)
        expect(stub).not_to have_been_requested
      end
    end

    # `c.response :raise_error` is in most Faraday stacks people have written
    # before, so it is what a caller adds by habit. It sits below the retry
    # middleware and raises for a 4xx or 5xx before this gem sees the
    # response: a GET answered 503 left as Faraday::ServerError without being
    # retried, and a 404 as Faraday::ResourceNotFound rather than the
    # NotFoundError that `exists?` and every caller's rescue are written for.
    context 'with middleware that raises for an error status first' do
      let(:raising) { ->(builder) { builder.response(:raise_error) } }

      it 'refuses it when the stack is built' do
        expect { unit_transport(middleware: raising) }
          .to raise_error(ZammadAPI::ConfigurationError, /raises a Faraday error for a 4xx or 5xx response before this gem sees it/)
      end

      it 'names the middleware it found' do
        expect { unit_transport(middleware: raising) }
          .to raise_error(ZammadAPI::ConfigurationError, /the configured middleware includes Faraday::Response::RaiseError/)
      end

      it 'says which middleware to drop' do
        expect { unit_transport(middleware: raising) }.to raise_error(ZammadAPI::ConfigurationError, /drop `c\.response :raise_error`/)
      end

      it 'refuses it where it was added by class' do
        expect { unit_transport(middleware: ->(builder) { builder.use(Faraday::Response::RaiseError) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /Faraday::Response::RaiseError/)
      end

      # The stub is for the path `find(1)` asks, and answers with a group. One
      # for the index, which this was, is not a request `find` makes, so the
      # assertion below held whether or not the GET went out before the
      # refusal.
      it 'sends nothing before refusing' do
        stub = stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, name: 'Users' }))

        expect { unit_client(middleware: raising).groups.find(1) }.to raise_error(ZammadAPI::ConfigurationError)
        expect(stub).not_to have_been_requested
      end
    end

    # A subclass has a name of its own, and only the name was asked. It is how
    # a caller adjusts what `raise_error` raises, and what it inherits is the
    # handler that raises before this gem sees the response.
    context 'with a subclass of a middleware it refuses' do
      let(:subclass) { stub_const('QuietRaiseError', Class.new(Faraday::Response::RaiseError)) }

      it 'refuses it for what it inherits' do
        expect { unit_transport(middleware: ->(builder) { builder.use(subclass) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /raises a Faraday error for a 4xx or 5xx response before this gem sees it/)
      end

      it 'names the subclass and the middleware it inherits from' do
        expect { unit_transport(middleware: ->(builder) { builder.use(subclass) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /includes QuietRaiseError, a subclass of Faraday::Response::RaiseError, which raises/)
      end

      # `c.response :raise_error` is not the line that added it.
      it 'says to drop the subclass rather than the spelling its parent has' do
        expect { unit_transport(middleware: ->(builder) { builder.use(subclass) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /it does neither: drop it from the `middleware:` callable\./)
      end

      it 'refuses one that was never given a name' do
        expect { unit_transport(middleware: ->(builder) { builder.use(Class.new(Faraday::Response::RaiseError)) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /includes an anonymous class, a subclass of Faraday::Response::RaiseError,/)
      end

      it 'refuses a subclass of the decoding middleware too' do
        expect { unit_transport(middleware: ->(builder) { builder.use(Class.new(Faraday::Response::Json)) }) }
          .to raise_error(ZammadAPI::ConfigurationError, /decodes the response body before this gem can/)
      end

      it 'sends nothing before refusing' do
        stub = stub_request(:get, "#{url}/1").with(query: hash_including({})).to_return(json_response({ id: 1, name: 'Users' }))

        expect { unit_client(middleware: ->(builder) { builder.use(subclass) }).groups.find(1) }.to raise_error(ZammadAPI::ConfigurationError)
        expect(stub).not_to have_been_requested
      end
    end

    # The build-time check knows the two above by name; anything
    # else that consumes the body is caught only once a response is in hand.
    context 'with a decoder the build-time check does not know by name' do
      subject(:transport) do
        unit_transport(middleware: lambda { |builder|
          builder.use(Class.new(Faraday::Middleware) do
            def on_complete(env) = env.body = { id: 1 }
          end)
        })
      end

      before { stub_request(:get, url).to_return(json_response([{ id: 1 }])) }

      it 'builds, because nothing named is in the stack' do
        expect { transport }.not_to raise_error
      end

      it 'refuses the response rather than stringifying what it got' do
        expect { transport.get('api/v1/groups', operation: 'test') }
          .to raise_error(ZammadAPI::ConfigurationError, /decoded the response body before this gem could/)
      end

      it 'names what it was handed instead of the body' do
        expect { transport.get('api/v1/groups', operation: 'test') }
          .to raise_error(ZammadAPI::ConfigurationError, /Faraday handed over Hash rather than the raw body/)
      end
    end

    it 'leaves a middleware that does not touch the body alone' do
      stub_request(:get, url).to_return(json_response([{ id: 1, name: 'Users' }]))

      response = unit_transport(middleware: ->(builder) { builder.response(:logger, Logger.new(File::NULL)) })
        .get('api/v1/groups', operation: 'test')

      expect(response.body).to eq([{ id: 1, name: 'Users' }])
    end

    it 'uses the configured adapter' do
      transport = unit_transport(adapter: :test)
      expect(transport.instance_variable_get(:@connection).adapter.name).to include('Adapter::Test')
    end

    # The adapter was set after the callable ran, and setting one replaces
    # the one that is there. A test that put the test adapter in through
    # the callable was on Net::HTTP, with nothing to say so.
    context 'with an adapter chosen inside the middleware callable' do
      let(:stubs) { Faraday::Adapter::Test::Stubs.new { it.get('/api/v1/groups') { [200, { 'Content-Type' => 'application/json' }, '[{"id":7}]'] } } }

      it 'keeps it' do
        transport = unit_transport(middleware: ->(faraday) { faraday.adapter :test, stubs })

        expect(transport.instance_variable_get(:@connection).adapter.name).to include('Adapter::Test')
      end

      it 'sends requests through it, with the arguments it was given' do
        transport = unit_transport(middleware: ->(faraday) { faraday.adapter :test, stubs })

        expect(transport.get('api/v1/groups', operation: 'test').body).to eq([{ id: 7 }])
        expect(a_request(:any, /zammad\.test/)).not_to have_been_made
      end

      it 'keeps it where it is the default adapter, named again to give it a block' do
        configured = nil
        transport  = unit_transport(middleware: ->(faraday) { faraday.adapter(Faraday.default_adapter) { configured = true } })
        stub_request(:get, url).to_return(json_response([]))
        transport.get('api/v1/groups', operation: 'test')

        expect(configured).to be(true)
      end

      it 'still puts the default adapter in where the callable chose none' do
        transport = unit_transport(middleware: ->(faraday) { faraday.use(Class.new(Faraday::Middleware)) })

        expect(transport.instance_variable_get(:@connection).adapter.name).to eq(Faraday::Adapter.lookup_middleware(Faraday.default_adapter).name)
      end

      # Two answers to one question, and whichever was kept the other was
      # dropped without a word.
      it 'refuses one named in the adapter option as well' do
        expect { unit_transport(adapter: :net_http, middleware: ->(faraday) { faraday.adapter :test, stubs }) }
          .to raise_error(ZammadAPI::ConfigurationError, /config adapter is :net_http, and the `middleware:` callable set an adapter as well \(Faraday::Adapter::Test\)/)
      end

      it 'refuses the pair even where both name the same adapter' do
        expect { unit_transport(adapter: :test, middleware: ->(faraday) { faraday.adapter :test, stubs }) }
          .to raise_error(ZammadAPI::ConfigurationError, /set an adapter as well/)
      end
    end

    it 'reports an unregistered adapter as a configuration error' do
      expect { unit_transport(adapter: :nonsense) }
        .to raise_error(ZammadAPI::ConfigurationError, /is not registered on Faraday::Adapter/)
    end

    it 'does not leak a Faraday error out of the client constructor' do
      expect { unit_client(adapter: :nonsense) }.to raise_error(ZammadAPI::ConfigurationError)
    end

    # Only Faraday::Error used to be wrapped, so the failures that do not come
    # from Faraday - the ones a caller is least equipped to place - escaped
    # raw, past the `rescue ZammadAPI::ConfigurationError` the constructor is
    # documented to need.
    it 'reports a proxy that is not a url as a configuration error' do
      expect { unit_transport(proxy: 'http://user:pa ss@host') }
        .to raise_error(ZammadAPI::ConfigurationError, /URI::InvalidURIError/)
    end

    it 'reports a middleware that raises as a configuration error' do
      expect { unit_transport(middleware: ->(_) { raise NameError, 'boom' }) }
        .to raise_error(ZammadAPI::ConfigurationError, /NameError: boom/)
    end

    # The backtrace into the caller's own code is the one thing the message
    # cannot carry, so the cause stays wherever it gives nothing away.
    it 'keeps the error a middleware raised as the cause' do
      failure = NameError.new('boom')

      expect { unit_transport(middleware: ->(_) { raise failure }) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be(failure) }
    end

    # The middleware is on a line of its own on purpose. A NameError's report
    # quotes the source line it was raised on, so with the proxy written on
    # that line the report would carry the password after all - and the cause
    # would be dropped, rightly.
    it 'keeps it beside a proxy that carries credentials, where the report does not quote them' do
      failure = NameError.new('boom')
      raising = ->(_) { raise failure }

      expect { unit_transport(proxy: 'http://user:s3cret@proxyhost:3128', middleware: raising) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be(failure) }
    end

    # Rendering a report is the error's own code, and this asks for it from
    # inside the rescue that turns the error into a ConfigurationError. A
    # `detailed_message` written without the `highlight:` keyword is all it
    # takes: `full_message` passes it one and gets ArgumentError back.
    context 'when the error a middleware raised cannot render its own report' do
      let(:failure) do
        Class.new(StandardError) do
          def detailed_message = "unreadable: #{message}"
        end.new('boom')
      end

      it 'has a report that raises, which is what this is about' do
        expect { failure.full_message(highlight: false) }.to raise_error(ArgumentError)
      end

      it 'still reports a configuration error' do
        expect { unit_transport(middleware: ->(_) { raise failure }) }
          .to raise_error(ZammadAPI::ConfigurationError, /config could not be used to build a connection: .*: boom/)
      end

      it 'drops the cause, which cannot be shown to quote nothing' do
        expect { unit_transport(middleware: ->(_) { raise failure }) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be_nil }
      end
    end

    it 'keeps the cause of an unregistered adapter' do
      expect { unit_transport(adapter: :nonsense) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be_a(Faraday::Error) }
    end

    it 'does not relabel an error this gem raised itself' do
      failure = ZammadAPI::NotFoundError.new(operation: 'test', resource_class: nil, detail: 'gone')

      expect { unit_transport(middleware: ->(_) { raise failure }) }
        .to raise_error(ZammadAPI::NotFoundError)
    end
  end

  describe '#with_on_behalf_of' do
    it 'sends the From header' do
      stub = stub_request(:get, url).with(headers: { 'From' => 'agent@example.com' }).to_return(json_response([]))
      unit_transport.with_on_behalf_of('agent@example.com').get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'sends an integer user id, which Net::HTTP will not stringify itself' do
      stub = stub_request(:get, url).with(headers: { 'From' => '42' }).to_return(json_response([]))
      unit_transport.with_on_behalf_of(42).get('api/v1/groups', operation: 'test')
      expect(stub).to have_been_requested
    end

    it 'records the scope as the string the header carries' do
      expect(unit_transport.with_on_behalf_of(42).on_behalf_of).to eq('42')
    end

    it 'keeps an unscoped transport unscoped' do
      expect(unit_transport.with_on_behalf_of(nil).on_behalf_of).to be_nil
    end

    # Every way to a From header goes through here, not only
    # Client#on_behalf_of, and a header with nothing in it is no scope.
    ['', '  ', "\u00A0"].each do |blank|
      it "refuses #{blank.inspect}, which Zammad reads as no From header" do
        expect { unit_transport.with_on_behalf_of(blank) }.to raise_error(ArgumentError, /on_behalf_of needs the login/)
      end
    end

    # Every object has a `to_s`, and the From header carried it.
    { 'an Array' => ['agent'], 'a Float' => 1.5, 'true' => true, 'any other object' => Object.new }.each do |kind, value|
      it "refuses #{kind}, which names no user, by its class" do
        expect { unit_transport.with_on_behalf_of(value) }
          .to raise_error(ArgumentError, /\Aon_behalf_of needs the login, email address or id of a user, as a String or an Integer, and was given #{value.class}:/)
      end
    end

    it 'takes a user id given as an Integer' do
      expect(unit_transport.with_on_behalf_of(7).on_behalf_of).to eq('7')
    end

    it 'takes a login given as a Symbol' do
      expect(unit_transport.with_on_behalf_of(:agent).on_behalf_of).to eq('agent')
    end

    # The blank check raised Encoding::CompatibilityError for text in an
    # encoding ASCII is no part of, for an identifier that names someone too.
    it 'refuses an identifier with a line break inside it' do
      expect { unit_transport.with_on_behalf_of("agent\nadmin") }.to raise_error(ArgumentError, /on_behalf_of holds a line break/)
    end

    it 'refuses a blank identifier given in UTF-16' do
      expect { unit_transport.with_on_behalf_of(' '.encode('UTF-16LE')) }.to raise_error(ArgumentError, /on_behalf_of needs the login/)
    end

    it 'holds an identifier given in UTF-16 as the same text in UTF-8' do
      expect(unit_transport.with_on_behalf_of('bob'.encode('UTF-16LE')).on_behalf_of).to eq('bob').and(have_attributes(encoding: Encoding::UTF_8))
    end

    # `String#to_s` hands back the receiver, so the scoped transport held the
    # caller's own String: a login buffer reused after the scope was taken
    # changed who every later request was performed for.
    context 'when the string it was given changes afterwards' do
      let(:login)  { +'agent@example.com' }
      let(:scoped) { unit_transport.with_on_behalf_of(login) }

      before do
        scoped
        login.replace('admin@example.com')
      end

      it 'goes on sending the scope it was given' do
        stub = stub_request(:get, url).with(headers: { 'From' => 'agent@example.com' }).to_return(json_response([]))
        scoped.get('api/v1/groups', operation: 'test')

        expect(stub).to have_been_requested
      end

      it 'goes on reporting the scope it was given' do
        expect(scoped.on_behalf_of).to eq('agent@example.com')
      end
    end

    it 'holds the scope frozen' do
      expect(unit_transport.with_on_behalf_of(+'agent@example.com').on_behalf_of).to be_frozen
    end

    it 'leaves the string it was given writable' do
      login = +'agent@example.com'
      unit_transport.with_on_behalf_of(login)

      expect(login).not_to be_frozen
    end

    it 'returns a different transport' do
      transport = unit_transport
      expect(transport.with_on_behalf_of('someone')).not_to be(transport)
    end

    it 'leaves the original transport unscoped' do
      transport = unit_transport
      transport.with_on_behalf_of('someone')
      expect(transport.on_behalf_of).to be_nil
    end

    it 'does not send a From header from the original transport' do
      transport = unit_transport
      transport.with_on_behalf_of('someone')

      stub_request(:get, url).to_return(json_response([]))
      transport.get('api/v1/groups', operation: 'test')

      expect(a_request(:get, url).with { |request| request.headers.key?('From') }).not_to have_been_made
    end

    it 'shares the underlying connection instead of rebuilding it' do
      transport = unit_transport
      scoped    = transport.with_on_behalf_of('someone')
      expect(scoped.instance_variable_get(:@connection)).to be(transport.instance_variable_get(:@connection))
    end
  end

  # Left to Ruby, inspect printed the Faraday connection, whose proxy options
  # carry the proxy password and whose middleware stack carries the token it
  # was built with.
  describe '#inspect' do
    let(:transport) do
      unit_transport(http_token: 'tok-s3cret', proxy: 'http://puser:pproxy-s3cret@proxy.test:8080')
    end

    it 'names the instance and the authentication scheme' do
      expect(unit_transport.inspect).to eq('#<ZammadAPI::Transport url="http://zammad.test/" auth=http_token>')
    end

    it 'names an on_behalf_of scope' do
      expect(unit_transport.with_on_behalf_of('agent@example.com').inspect).to include('on_behalf_of="agent@example.com"')
    end

    it 'does not print the access token' do
      expect(transport.inspect).not_to include('tok-s3cret')
    end

    it 'does not print the proxy password' do
      expect(transport.inspect).not_to include('pproxy-s3cret')
    end

    it 'does not print a basic authentication password' do
      basic = unit_transport(http_token: nil, user: 'u', password: 'pw-s3cret')
      expect(basic.inspect).not_to include('pw-s3cret')
    end

    it 'keeps both out of what pp prints too' do
      expect(transport.pretty_inspect).not_to match(/tok-s3cret|pproxy-s3cret/)
    end
  end

  # ActiveSupport serializes an object as its instance variables, and one of
  # a transport's is the Faraday connection. It is not loaded here: what is
  # asked is what it asks, and that the answer is this class's own.
  describe 'serializing as JSON' do
    let(:transport) do
      unit_transport(http_token: 'tok-s3cret', proxy: 'http://puser:pproxy-s3cret@proxy.test:8080')
    end

    it 'answers as_json itself, where ActiveSupport would answer for any object' do
      expect(described_class.instance_method(:as_json).owner).to be(described_class)
    end

    it 'is the instance and the authentication scheme' do
      expect(transport.as_json).to eq({ url: 'http://zammad.test/', auth: :http_token })
    end

    it 'names an on_behalf_of scope' do
      expect(transport.with_on_behalf_of('agent@example.com').as_json).to include(on_behalf_of: 'agent@example.com')
    end

    it 'writes that as a JSON object, with neither the token nor the proxy password' do
      expect(JSON.generate(transport: transport)).to eq('{"transport":{"url":"http://zammad.test/","auth":"http_token"}}')
    end
  end

  describe '#with_config' do
    it 'applies the new configuration' do
      expect(unit_transport.with_config(ZammadAPI::Config.new(**unit_config(timeout: 7))).config.timeout).to eq(7)
    end

    it 'carries the on_behalf_of scope over' do
      derived = unit_transport.with_on_behalf_of('agent@example.com')
        .with_config(ZammadAPI::Config.new(**unit_config(timeout: 7)))

      expect(derived.on_behalf_of).to eq('agent@example.com')
    end

    it 'keeps a subclass on its own kind, rather than reverting to a real one' do
      recording = Class.new(described_class)
      stub_const('RecordingTransport', recording)

      derived = recording.new(ZammadAPI::Config.new(**unit_config)).with_config(ZammadAPI::Config.new(**unit_config(timeout: 7)))

      expect(derived).to be_a(recording)
    end

    it 'returns a different transport' do
      transport = unit_transport
      expect(transport.with_config(transport.config)).not_to be(transport)
    end
  end

  describe 'logging' do
    subject(:log) { log_device.string }

    let(:log_device) { StringIO.new }
    let(:logger) { Logger.new(log_device, level: Logger::DEBUG) }

    before do
      stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201))
      unit_transport(logger: logger, user: 'u', password: 'pw-s3cret', http_token: nil)
        .post('api/v1/groups', operation: 'test', body: { login: 'jane', password: 'pw-s3cret' })
    end

    it 'logs the request' do
      expect(log).to include('Zammad API request: POST api/v1/groups')
    end

    it 'logs the response status' do
      expect(log).to include('Zammad API response: POST api/v1/groups -> 201')
    end

    it 'never logs a password from the payload' do
      expect(log).not_to include('pw-s3cret')
    end

    it 'marks the redacted payload value' do
      expect(log).to include('"password" => "[REDACTED]"')
    end

    it 'keeps non-sensitive payload values' do
      expect(log).to include('"login" => "jane"')
    end

    it 'stays silent by default' do
      stub_request(:get, url).to_return(json_response([]))

      expect { unit_transport.get('api/v1/groups', operation: 'test') }
        .to output('').to_stdout.and output('').to_stderr
    end

    context 'with credential-bearing payload keys' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }

      before do
        stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201))
        unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)).post(
          'api/v1/groups',
          operation: 'test',
          body:      {
            login:            'jane',
            keyboard_layout:  'de',
            password_confirm: 'confirm-s3cret',
            passwd:           'passwd-s3cret',
            access_token:     'access-s3cret',
            refresh_token:    'refresh-s3cret',
            client_secret:    'client-s3cret',
            api_key:          'api-key-s3cret',
            apikey:           'apikey-s3cret',
            key:              'key-s3cret'
          }
        )
      end

      it 'redacts a password_confirm' do
        expect(log).not_to include('confirm-s3cret')
      end

      it 'redacts an access_token' do
        expect(log).not_to include('access-s3cret')
      end

      it 'redacts a refresh_token' do
        expect(log).not_to include('refresh-s3cret')
      end

      it 'redacts an api_key' do
        expect(log).not_to include('api-key-s3cret')
      end

      it 'redacts an apikey, which nothing separates the word in' do
        expect(log).not_to include('apikey-s3cret')
      end

      it 'redacts a bare key' do
        expect(log).not_to include('key-s3cret')
      end

      it 'redacts a passwd' do
        expect(log).not_to include('passwd-s3cret')
      end

      # Matched as a word, so that a key merely containing the letters stays
      # readable in the log rather than being blanked for nothing.
      it 'leaves a key whose name only contains one of the words alone' do
        expect(log).to include('"keyboard_layout" => "de"')
      end

      it 'redacts a client_secret' do
        expect(log).not_to include('client-s3cret')
      end

      it 'still keeps a non-sensitive value' do
        expect(log).to include('"login" => "jane"')
      end
    end

    # The names Zammad filters from its own log, in
    # config/initializers/filter_parameter_logging.rb, that matched no word
    # here: an LDAP source's bind password and a PGP key's passphrase were
    # logged beside a redacted `key`.
    describe 'the keys Zammad filters from its own log' do
      %w[bind_pw passphrase privateKey sshKeys publicKeyId otp otp_code totp hotp salt pw_salt].each do |name|
        it "redacts #{name}" do
          expect(described_class.redact({ name => 's3cret' })).to eq({ name => '[REDACTED]' })
        end
      end

      # Matched as words, so that a key merely containing the letters stays
      # readable.
      %w[footprint basalt hotKeyboard Keyboard monkey_id bind_user].each do |name|
        it "leaves #{name} alone" do
          expect(described_class.redact({ name => 'shown' })).to eq({ name => 'shown' })
        end
      end

      it 'redacts a bind password inside the preferences of an LDAP source' do
        expect(described_class.redact({ name: 'x', preferences: { bind_user: 'cn=admin', bind_pw: 'hunter2' } }))
          .to eq({ name: 'x', preferences: { bind_user: 'cn=admin', bind_pw: '[REDACTED]' } })
      end

      it 'redacts them where they are written into a request path' do
        expect(described_class.redact_path('api/v1/x?passphrase=opensesame&privateKey=abc&page=2'))
          .to eq('api/v1/x?passphrase=[REDACTED]&privateKey=[REDACTED]&page=2')
      end
    end

    # A body handed over as a String is the caller's own encoding. Redaction
    # goes by key and found none in a String, so the payload line printed it
    # as it stood.
    context 'with a body handed over as a String' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }
      let(:transport)  { unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)) }

      before { stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201)) }

      it 'redacts a credential in one that is JSON' do
        transport.post('api/v1/groups', operation: 'test', body: '{"login":"jane","password":"string-s3cret"}')

        expect(log).not_to include('string-s3cret')
      end

      it 'keeps what is not a credential readable, redacted by key like a Hash' do
        transport.post('api/v1/groups', operation: 'test', body: '{"login":"jane","password":"string-s3cret"}')

        expect(log).to include('Zammad API payload: {"login" => "jane", "password" => "[REDACTED]"}')
      end

      it 'redacts one nested in a JSON list' do
        transport.post('api/v1/groups', operation: 'test', body: '[{"user":{"api_key":"string-s3cret"}}]')

        expect(log).not_to include('string-s3cret')
      end

      it 'does not log one that is not JSON, and says how much was left out' do
        transport.post('api/v1/groups', operation: 'test', body: 'login=jane&password=string-s3cret')

        expect(log).not_to include('string-s3cret')
        expect(log).to include('Zammad API payload: "[33 bytes that are not a JSON object or array, not logged]"')
      end

      it 'does not log a JSON value with no keys to go by' do
        transport.post('api/v1/groups', operation: 'test', body: '"string-s3cret"')

        expect(log).not_to include('string-s3cret')
      end

      it 'does not raise for bytes that are not text' do
        expect { transport.post('api/v1/groups', operation: 'test', body: "\xFF\xFEstring-s3cret".b) }.not_to raise_error
        expect(log).not_to include('string-s3cret')
      end

      it 'still sends the body as it was given' do
        transport.post('api/v1/groups', operation: 'test', body: '{"login":"jane","password":"string-s3cret"}')

        expect(a_request(:post, url).with(body: '{"login":"jane","password":"string-s3cret"}')).to have_been_made
      end
    end

    # The payload line printed the body the caller handed over, redacted by
    # key through its Hashes and Arrays, and anything else in it by
    # `inspect`. An object that writes its own JSON goes out as keys and
    # values like any Hash, and was printed with every one of them.
    context 'with a body holding an object that is neither a Hash nor an Array' do
      subject(:log) { log_device.string }

      let(:log_device)  { StringIO.new }
      let(:transport)   { unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)) }
      let(:credentials) { Data.define(:login, :password) { def to_json(*) = to_h.to_json(*) }.new(login: 'jane', password: 'object-s3cret') }

      before { stub_request(:post, url).to_return(json_response({ id: 1 }, status: 201)) }

      it 'redacts a credential in one that writes its own JSON' do
        transport.post('api/v1/groups', operation: 'test', body: credentials)

        expect(log).not_to include('object-s3cret')
      end

      it 'prints it as it is sent, redacted by key' do
        transport.post('api/v1/groups', operation: 'test', body: credentials)

        expect(log).to include('Zammad API payload: {"login" => "jane", "password" => "[REDACTED]"}')
      end

      it 'redacts a credential in one that a Hash holds' do
        transport.post('api/v1/groups', operation: 'test', body: { note: 'x', user: credentials })

        expect(log).to include('Zammad API payload: {"note" => "x", "user" => {"login" => "jane", "password" => "[REDACTED]"}}')
      end

      it 'redacts a credential in one that an Array holds' do
        transport.post('api/v1/groups', operation: 'test', body: [credentials])

        expect(log).not_to include('object-s3cret')
      end

      # An object that is sent as its `as_json` goes out as keys and values
      # too, and `inspect` printed the object in their place.
      it 'redacts a credential in one that is sent as its as_json' do
        described = Struct.new(:password) { def as_json(*) = to_h.transform_keys(&:to_s) }.new('object-s3cret')
        transport.post('api/v1/groups', operation: 'test', body: { user: described })

        expect(log).to include('Zammad API payload: {"user" => {"password" => "[REDACTED]"}}')
      end

      # JSON has no type for such an object, and it is refused before the
      # request is logged. It was sent as its `to_s`, which names the class
      # and no more, while the log printed its `inspect`, which lists what
      # it holds.
      it 'does not print what an object holds and no request carries' do
        holder = Class.new { def initialize = @password = 'object-s3cret' }.new

        expect { transport.post('api/v1/groups', operation: 'test', body: { user: holder }) }.to raise_error(ZammadAPI::Error)
        expect(log).not_to include('object-s3cret')
      end

      it 'does not log a body that is one value with no keys to go by' do
        transport.post('api/v1/groups', operation: 'test', body: :'object-s3cret')

        expect(log).not_to include('object-s3cret')
        expect(log).to include('Zammad API payload: "[15 bytes that are not a JSON object or array, not logged]"')
      end

      it 'still sends the body as it was given' do
        transport.post('api/v1/groups', operation: 'test', body: { user: credentials })

        expect(a_request(:post, url).with(body: '{"user":{"login":"jane","password":"object-s3cret"}}')).to have_been_made
      end
    end

    # The request line printed the `query:` the caller handed over, redacted
    # by key through its Hashes. What it held that converts to a Hash, and
    # is sent as one, was printed by `inspect` under the key it sat at.
    context 'with a query that carries a credential' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }
      let(:transport)  { unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)) }

      before { stub_request(:get, url).with(query: hash_including({})).to_return(json_response([])) }

      it 'redacts it by key, in the query as it is sent' do
        transport.get('api/v1/groups', operation: 'test', query: { page: 1, token: 'query-s3cret' })

        expect(log).to include('Zammad API request: GET api/v1/groups query={"page" => "1", "token" => "[REDACTED]"}')
      end

      it 'redacts it in strong parameters the query holds' do
        transport.get('api/v1/groups', operation: 'test', query: { filter: StrongParameters.new(page: 1, token: 'query-s3cret') })

        expect(log).to include('query={"filter" => {"page" => "1", "token" => "[REDACTED]"}}')
        expect(log).not_to include('query-s3cret')
      end
    end

    # A raw request may carry its query in the path. The `query:` Hash is
    # redacted by key, and the same parameter written into the path was
    # printed in full, in the request line and in the response line.
    context 'with a query string written into the path' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }
      let(:verify)     { 'api/v1/users/password_reset_verify?token=path-s3cret&locale=de' }

      before do
        stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/password_reset_verify").with(query: hash_including({})).to_return(json_response({}))
        unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)).get(verify, operation: 'test')
      end

      it 'redacts a credential in it' do
        expect(log).not_to include('path-s3cret')
      end

      it 'marks it in the request line, and keeps the other parameters' do
        expect(log).to include('Zammad API request: GET api/v1/users/password_reset_verify?token=[REDACTED]&locale=de')
      end

      it 'marks it in the response line' do
        expect(log).to include('Zammad API response: GET api/v1/users/password_reset_verify?token=[REDACTED]&locale=de -> 200')
      end

      it 'still sends the query as it was given' do
        expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/password_reset_verify").with(query: { 'token' => 'path-s3cret', 'locale' => 'de' }))
          .to have_been_made
      end
    end

    # A raw request takes headers of its own and the request line prints
    # them. `Cookie` carries a session and matched none of the credential
    # words, so it was written out in full.
    context 'with credential-bearing headers' do
      subject(:log) { log_device.string }

      let(:log_device) { StringIO.new }

      before do
        stub_request(:get, url).to_return(json_response([]))
        unit_transport(logger: Logger.new(log_device, level: Logger::DEBUG)).get(
          'api/v1/groups',
          operation: 'test',
          headers:   {
            'Cookie'              => '_zammad_session=cookie-s3cret',
            'Proxy-Authorization' => 'Basic proxy-s3cret',
            'X-CSRF-Token'        => 'csrf-s3cret',
            'X-Request-Id'        => 'request-123'
          }
        )
      end

      it 'redacts a Cookie' do
        expect(log).not_to include('cookie-s3cret')
      end

      it 'marks the redacted header, under the name it is sent as' do
        expect(log).to include('"cookie" => "[REDACTED]"')
      end

      it 'redacts a Proxy-Authorization' do
        expect(log).not_to include('proxy-s3cret')
      end

      it 'redacts a token header' do
        expect(log).not_to include('csrf-s3cret')
      end

      it 'keeps a header that carries no credential' do
        expect(log).to include('"x-request-id" => "request-123"')
      end

      it 'still sends the headers as they were given' do
        expect(a_request(:get, url).with(headers: { 'Cookie' => '_zammad_session=cookie-s3cret', 'Proxy-Authorization' => 'Basic proxy-s3cret' }))
          .to have_been_made
      end
    end
  end

  # `request` documents that every failure leaves it as a ZammadAPI::Error.
  # Faraday::SSLError was handled and its unwrapped counterpart was not, so a
  # certificate mismatch through an adapter that does not wrap - an adapter
  # this gem lets a caller choose - went straight past the rescue.
  describe 'a TLS failure through an adapter that does not wrap it' do
    before { BareTlsAdapter.attempts = [] }

    def bare_tls_transport(**overrides)
      unit_transport(adapter: :bare_tls, retry_interval: 0.01, **overrides)
    end

    it 'maps it to ConnectionError rather than letting it out raw' do
      expect { bare_tls_transport.get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError, /TLS handshake with .* failed/)
    end

    it 'is catchable as the gem error every caller rescues' do
      expect { bare_tls_transport.get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::Error)
    end

    # A rejected certificate is a fact about the instance, not a transient
    # failure: retrying only delays the error by the backoff.
    it 'does not retry it' do
      expect { bare_tls_transport(retries: 2).get('api/v1/groups', operation: 'test') }
        .to raise_error(ZammadAPI::ConnectionError)
      expect(BareTlsAdapter.attempts.size).to eq(1)
    end

    it 'keeps the unwrapped TLS error out of the retry list' do
      expect(described_class::RETRIABLE_EXCEPTIONS).not_to include(*described_class::SSL_ERRORS)
    end
  end

  # The error Faraday or URI raises quotes the value it rejected, and for a
  # proxy that value carries its credentials - into a message that lands in
  # every log and exception report.
  describe 'a connection that cannot be built from a credential-bearing proxy' do
    let(:proxy) { 'http://user:pa ss@proxyhost:3128' }

    it 'reports it as a configuration error' do
      expect { unit_transport(proxy: proxy) }.to raise_error(ZammadAPI::ConfigurationError)
    end

    it 'keeps the proxy password out of the message' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to include('pa ss') }
    end

    it 'still says which value was rejected' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError, %r{http://\[REDACTED\]@proxyhost:3128})
    end

    # The message is not what a log or an error tracker prints. They print
    # the report, and Ruby had attached the error being rescued as the cause:
    # the redacted message went out with the original, password and all,
    # right behind it.
    it 'keeps the proxy password out of the whole report, not just the message' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to include('pa ss') }
    end

    it 'does not carry the error that quotes the password along as its cause' do
      expect { unit_transport(proxy: proxy) }
        .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be_nil }
    end

    it 'still names the class of the error it replaced' do
      expect { unit_transport(proxy: proxy) }.to raise_error(ZammadAPI::ConfigurationError, /URI::InvalidURIError/)
    end

    # The error being replaced may be clean itself and still have the
    # password one level down, and a report prints every level.
    context 'when the error quotes the proxy only further down its own chain' do
      let(:proxy) { 'http://user:s3cret@proxyhost:3128' }

      let(:wrapping) do
        lambda do |_|
          raise URI::InvalidURIError, "bad URI: #{proxy}"
        rescue URI::InvalidURIError
          raise ArgumentError, 'the proxy could not be used'
        end
      end

      it 'has nothing to redact in the message' do
        expect { unit_transport(proxy: proxy, middleware: wrapping) }
          .to raise_error(ZammadAPI::ConfigurationError, /ArgumentError: the proxy could not be used/)
      end

      it 'keeps the password out of the whole report all the same' do
        expect { unit_transport(proxy: proxy, middleware: wrapping) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to include('s3cret') }
      end
    end

    # A # ends the authority early, so the redaction found no credential in
    # what was left of it and the message quoted the password in full.
    context 'when the password carries a character that ends the authority' do
      let(:proxy) { 'http://user:pa#ss-s3cret@proxyhost:3128' }

      it 'keeps the password out of the message' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to match(/pa#ss|s3cret/) }
      end

      it 'still says which value was rejected' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError, %r{http://\[REDACTED\]@proxyhost:3128})
      end

      it 'keeps the password out of the whole report' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to match(/pa#ss|s3cret/) }
      end
    end

    context 'when it is the instance url that carries such a password' do
      it 'keeps the password out of the message' do
        expect { unit_transport(url: 'https://admin:pa#ss-s3cret@zammad.test/') }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to match(/pa#ss|s3cret/) }
      end
    end

    # The error quotes what it rejected through `inspect`, which escapes the
    # backslash - so the text in the message stopped matching the configured
    # value and the substring swap redacted nothing at all.
    context 'when the value carries a backslash, which inspect escapes' do
      let(:proxy) { 'http://user:secret@proxyhost/a\0b' }

      it 'still keeps the password out of the message' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to include('secret') }
      end
    end

    # URI turns away a URL holding a character outside ASCII, and quotes it
    # through `dump`, which writes that character as an escape where
    # `inspect` leaves it standing. Neither spelling that was looked for
    # matched, so the password stayed in the message and in the cause.
    context 'when the password carries a character outside ASCII, which dump escapes' do
      let(:proxy) { 'http://user:pässwörd@proxyhost:3128' }

      it 'keeps the password out of the message' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.message).not_to match(/ssw|user:/) }
      end

      it 'still says which value was rejected' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError, %r{URI must be ascii only "http://\[REDACTED\]@proxyhost:3128"})
      end

      it 'keeps the password out of the whole report' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to match(/ssw|user:/) }
      end

      it 'does not carry the error that quotes the password along as its cause' do
        expect { unit_transport(proxy: proxy) }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.cause).to be_nil }
      end

      it 'keeps it out of the message where the instance url carries it' do
        expect { unit_transport(url: 'https://admin:pässwörd@zammad.test/') }
          .to raise_error(ZammadAPI::ConfigurationError) { |error| expect(error.full_message(highlight: false)).not_to match(/ssw|admin:/) }
      end
    end

    # `\0` in a gsub replacement String expands to the matched text, which is
    # the unredacted value.
    context 'when the value carries a sequence a gsub replacement would expand' do
      let(:proxy) { 'http://user:secret@proxyhost/a\0b' }

      it 'does not put the credential back through the replacement' do
        message = begin
          unit_transport(proxy: proxy)
          nil
        rescue ZammadAPI::ConfigurationError => e
          e.message
        end

        expect(message.scan('user:secret')).to be_empty
      end
    end
  end
end
