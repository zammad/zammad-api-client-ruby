# frozen_string_literal: true

RSpec.describe ZammadAPI::Response do
  def build(status: 200, body: { a: 1 }, raw_body: '{"a":1}', headers: {}, json: !body.is_a?(String))
    described_class.new(status: status, headers: headers, body: body, raw_body: raw_body, json: json)
  end

  describe '#success?' do
    [200, 201, 204, 299].each do |status|
      it "is true for #{status}" do
        expect(build(status: status)).to be_success
      end
    end

    [199, 300, 400, 500].each do |status|
      it "is false for #{status}" do
        expect(build(status: status)).not_to be_success
      end
    end
  end

  # Read by the collection walk and by the has_many guard, which each used to
  # carry their own copy: one kept the header name in a private constant and
  # refused a negative count, the other hardcoded the string and accepted any
  # Integer.
  describe '#reported_total' do
    it 'reads the count the endpoint reported' do
      expect(build(headers: { 'x-total-count' => '7' }).reported_total).to eq(7)
    end

    it 'is nil when the endpoint reported none' do
      expect(build.reported_total).to be_nil
    end

    it 'is nil for a header that is not a count' do
      expect(build(headers: { 'x-total-count' => 'many' }).reported_total).to be_nil
    end

    it 'is nil for a count that cannot describe a result' do
      expect(build(headers: { 'x-total-count' => '-1' }).reported_total).to be_nil
    end

    # `Integer(5, 10, exception: false)` is nil - a base cannot be given for a
    # non-String and the exception is swallowed - so a count on a Response
    # built by hand would read as no count at all, which is the one answer that
    # turns the guard off silently.
    it 'reads a count given as an Integer' do
      expect(build(headers: { 'x-total-count' => 7 }).reported_total).to eq(7)
    end

    it 'reads a zero as the count it is, not as no count at all' do
      expect(build(headers: { 'x-total-count' => '0' }).reported_total).to eq(0)
    end
  end

  describe '#json?' do
    it 'is true when the body was decoded' do
      expect(build).to be_json
    end

    it 'is false when the body is the untouched raw body' do
      raw = '<html></html>'
      expect(build(body: raw, raw_body: raw)).not_to be_json
    end

    it 'reports what the decoder recorded, not whether the two bodies differ' do
      expect(build(body: '"a string"', raw_body: '"a string"', json: true)).to be_json
    end
  end

  describe '#decoded' do
    it 'returns an object body when one is expected' do
      expect(build(body: { a: 1 }).decoded(:object, operation: 'find object')).to eq(a: 1)
    end

    it 'returns an array body when one is expected' do
      expect(build(body: [{ a: 1 }]).decoded(:array, operation: 'get list')).to eq([{ a: 1 }])
    end

    it 'raises when an object was expected but a list arrived' do
      expect { build(body: []).decoded(:object, operation: 'find object') }
        .to raise_error(ZammadAPI::ParseError, "Can't find object: expected a JSON object, got Array")
    end

    it 'raises when a list was expected but an object arrived' do
      expect { build(body: {}).decoded(:array, operation: 'get list') }
        .to raise_error(ZammadAPI::ParseError, "Can't get list: expected a JSON array, got Hash")
    end

    it 'raises when the body was never JSON' do
      expect { build(body: '<html>', raw_body: '<html>').decoded(:object, operation: 'find object') }
        .to raise_error(ZammadAPI::ParseError, /got String/)
    end

    it 'names the resource class in the message' do
      expect { build(body: []).decoded(:object, operation: 'find object', resource_class: ZammadAPI::Resources::User) }
        .to raise_error(/\(ZammadAPI::Resources::User\)/)
    end

    it 'accepts an empty list' do
      expect(build(body: []).decoded(:array, operation: 'get list')).to eq([])
    end

    # An unexpanded search answers with ids. Passing them on stored an Integer
    # as a record's attributes, and the first reader died with a TypeError
    # from deep inside the gem.
    it 'raises for a list of scalars rather than building records from them' do
      expect { build(body: [1, 2, 3]).decoded(:array, operation: 'get list') }
        .to raise_error(ZammadAPI::ParseError, "Can't get list: expected a JSON array of objects, got an array holding Integer")
    end

    it 'raises for a list that is only partly objects' do
      expect { build(body: [{ id: 1 }, 'nope']).decoded(:array, operation: 'get list') }
        .to raise_error(ZammadAPI::ParseError, /an array holding String/)
    end

    it 'names the resource class when a list element has the wrong shape' do
      expect { build(body: [1]).decoded(:array, operation: 'get list', resource_class: ZammadAPI::Resources::User) }
        .to raise_error(/\(ZammadAPI::Resources::User\)/)
    end
  end

  it 'is immutable' do
    expect(build).to be_frozen
  end
end
