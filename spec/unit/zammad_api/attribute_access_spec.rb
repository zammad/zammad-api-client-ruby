# frozen_string_literal: true

RSpec.describe ZammadAPI::AttributeAccess do
  subject(:record) { record_class.new(attributes) }

  let(:record_class) do
    Class.new do
      include ZammadAPI::AttributeAccess

      def initialize(attributes)
        @attributes = frozen_attributes(attributes)
      end
    end
  end

  let(:attributes) do
    {
      'id'          => 1,
      'name'        => 'Support',
      'preferences' => { 'notes' => [{ 'body' => 'hello' }] }
    }
  end

  describe 'key normalization' do
    it 'symbolizes top level keys' do
      expect(record.attributes.keys).to eq(%i[id name preferences])
    end

    it 'symbolizes nested hash keys' do
      expect(record.attributes[:preferences].keys).to eq([:notes])
    end

    it 'symbolizes hash keys inside arrays' do
      expect(record.attributes[:preferences][:notes].first).to eq({ body: 'hello' })
    end

    it 'leaves keys alone that cannot become symbols' do
      expect(record_class.new(1 => 'one').attributes).to eq(1 => 'one')
    end
  end

  describe 'reading' do
    it 'reads through a reader method' do
      expect(record.name).to eq('Support')
    end

    it 'reads through #[]' do
      expect(record[:name]).to eq('Support')
    end

    it 'accepts a string key in #[]' do
      expect(record['name']).to eq('Support')
    end

    it 'exposes the id' do
      expect(record.id).to eq(1)
    end

    # A reader used to answer nil here, which made a typo a silent nil that
    # flowed on into whatever was written with it - and put respond_to? and
    # the call itself at odds, since respond_to?(:custom_field) was false
    # throughout.
    it 'raises for an attribute the record does not carry' do
      expect { record.custom_field }.to raise_error(NoMethodError, /undefined attribute custom_field/)
    end

    it 'names the readers that tolerate an absent attribute' do
      expect { record.custom_field }.to raise_error(NoMethodError, /fetch\(:custom_field, nil\)/)
    end

    it 'says the record may be one Zammad served less of' do
      expect { record.custom_field }.to raise_error(NoMethodError, /reduced object/)
    end

    it 'lists what the record does carry, so the spelling can be compared' do
      expect { record.custom_field }.to raise_error(NoMethodError, /carries id, name, preferences/)
    end

    # A key that could not become a Symbol is left as it arrived, so sorting
    # the keys themselves would raise from inside the message.
    it 'lists mixed keys without raising from the message itself' do
      expect { record_class.new(1 => 'one', 'name' => 'X').custom_field }
        .to raise_error(NoMethodError, /carries 1, name/)
    end

    it 'says so plainly for a record that carries nothing' do
      expect { record_class.new({}).custom_field }
        .to raise_error(NoMethodError, /carries no attributes at all/)
    end

    it 'carries the name and the receiver a bare NoMethodError would' do
      expect { record.custom_field }.to raise_error(NoMethodError) do |error|
        expect(error.name).to eq(:custom_field)
        expect(error.receiver).to be(record)
      end
    end

    it 'still reads an attribute the record carries but Zammad left nil' do
      expect(record_class.new('note' => nil).note).to be_nil
    end

    it 'leaves [] and fetch answering for an absent attribute' do
      expect(record[:custom_field]).to be_nil
      expect(record.fetch(:custom_field, 'fallback')).to eq('fallback')
    end

    it 'reports known attributes via #key?' do
      expect(record.key?(:name)).to be(true)
    end

    it 'returns a copy from #to_h' do
      record.to_h[:name] = 'changed'
      expect(record.name).to eq('Support')
    end
  end

  describe 'immutability' do
    it 'freezes the attribute hash' do
      expect { record.attributes[:name] = 'changed' }.to raise_error(FrozenError)
    end

    it 'freezes a nested hash' do
      expect { record.attributes[:preferences][:notes] = [] }.to raise_error(FrozenError)
    end

    it 'freezes a nested array' do
      expect { record.attributes[:preferences][:notes] << {} }.to raise_error(FrozenError)
    end

    it 'freezes a hash inside an array' do
      expect { record.attributes[:preferences][:notes].first[:body] = 'changed' }.to raise_error(FrozenError)
    end

    it 'freezes a string value' do
      expect { record.name << '!' }.to raise_error(FrozenError)
    end

    it 'hands out a deep copy from #to_h' do
      copy = record.to_h
      copy[:preferences][:notes].first[:body] = 'changed'

      expect(record.attributes[:preferences][:notes].first[:body]).to eq('hello')
    end

    it 'hands out mutable strings from #to_h' do
      copy = record.to_h
      copy[:name] << '!'

      expect(record.name).to eq('Support')
    end
  end

  describe '#fetch' do
    it 'returns the value for a known attribute' do
      expect(record.fetch(:name)).to eq('Support')
    end

    it 'raises for an unknown attribute' do
      expect { record.fetch(:nope) }.to raise_error(KeyError)
    end

    it 'supports a default' do
      expect(record.fetch(:nope, 'fallback')).to eq('fallback')
    end

    # Hash#fetch refuses a third argument, and so does this: collected with a
    # splat and read as `default.first`, `fetch(:a, :b, :c)` - a multi-key read
    # this has never been - was answered with `:b`.
    it 'refuses more than one fallback, the way Hash#fetch does' do
      expect { record.fetch(:nope, 'one', 'two') }
        .to raise_error(ArgumentError, 'wrong number of arguments (given 3, expected 1..2)')
    end

    # Hash#fetch warns and then ignores the default. Silently picking one of
    # two fallbacks a caller cannot have meant to pass together is the same
    # swallowed mistyped call the arity check above refuses.
    # rubocop:disable Lint/UselessDefaultValueArgument -- the call under test
    it 'says so when a block supersedes the default, the way Hash#fetch does' do
      expect { record.fetch(:nope, 'fallback') { 'block' } }
        .to output(/block supersedes default value argument/).to_stderr
    end

    it 'still answers from the block when both were given' do
      expect { expect(record.fetch(:nope, 'fallback') { 'block' }).to eq('block') }.to output.to_stderr
    end

    # Hash#fetch names the line that made the call. A bare Kernel#warn named
    # nothing at all - neither the call site nor the library it came from,
    # which in an application with several such calls is everything the reader
    # needs. `uplevel` supplies both that location and the `warning: ` prefix.
    it 'names the line that made the call, the way Hash#fetch does' do
      expect { record.fetch(:nope, 'fallback') { 'block' } }
        .to output(/attribute_access_spec\.rb:\d+: warning: block supersedes/).to_stderr
    end
    # rubocop:enable Lint/UselessDefaultValueArgument
  end

  # `record[:x] = v` reached method_missing as `:[]=`, which the writer branch
  # took for an attribute called `[]` - it staged the index as the value, lost
  # the write, and sent `{"[]": "x"}` on the next save. Ruby's operators end in
  # `=` too, so `record <= 5` did the same for an attribute called `<`.
  describe '#[]=' do
    it 'goes through the same refusal a named writer does on a read-only record' do
      expect { record[:note] = 'x' }.to raise_error(NoMethodError, /attributes are read-only/)
    end

    it 'names the attribute that was tried, not the operator' do
      expect { record[:note] = 'x' }.to raise_error(NoMethodError, /tried to set note/)
    end

    # `[]=` is a defined method, so respond_to_missing? never sees it: a
    # read-only record claimed the one writer it has while denying every named
    # one, then raised when it was called - the invariant the writer branch of
    # respond_to_missing? is conditional for.
    it 'is not claimed by a record that would refuse it' do
      expect(record).not_to respond_to(:[]=)
    end

    it 'agrees with the named writers on the same record' do
      expect(record.respond_to?(:[]=)).to eq(record.respond_to?(:name=))
    end

    # `respond_to?` takes either spelling and Ruby does not normalise the
    # argument, so a Symbol-only comparison let the String fall through to the
    # definition and answer true on a record that refuses every write.
    it 'answers the same for the String spelling' do
      # rubocop:disable-next Performance/StringIdentifierArgument -- the String spelling is the point
      expect(record.respond_to?('[]=')).to eq(record.respond_to?(:[]=))
    end
  end

  describe 'a name that only looks like a writer' do
    it 'does not invent an attribute from a comparison operator' do
      # Sent rather than written as `record <= 5`, which RuboCop reads as a
      # void literal and rewrites away, taking the spec with it.
      expect { record.public_send(:<=, 5) }.to raise_error(NoMethodError)

      expect(record.attributes.keys).not_to include(:<)
    end

    it 'is not claimed as a writer' do
      expect(record).not_to respond_to(:<=)
    end
  end

  describe '#respond_to?' do
    it 'is true for a known attribute' do
      expect(record).to respond_to(:name)
    end

    it 'is false for an unknown attribute' do
      expect(record).not_to respond_to(:nope)
    end

    it 'is false for a writer on a read-only record, which would raise' do
      expect(record).not_to respond_to(:anything=)
    end

    it 'is true for any writer on a record that stages changes' do
      expect(ZammadAPI::Resources::Group.new(unit_transport)).to respond_to(:anything=)
    end

    it 'is false for a predicate' do
      expect(record).not_to respond_to(:name?)
    end
  end

  describe 'method names that are not attributes' do
    it 'raises NoMethodError for a bang method, so typos surface' do
      expect { record.save! }.to raise_error(NoMethodError)
    end

    it 'raises NoMethodError for a predicate' do
      expect { record.active? }.to raise_error(NoMethodError)
    end
  end

  describe 'pattern matching' do
    it 'matches on attribute values' do
      result = case record
               in { name: 'Support' } then :matched
               else :not_matched
               end
      expect(result).to eq(:matched)
    end

    it 'binds matched values' do
      case record
      in { name: String => name }
        expect(name).to eq('Support')
      end
    end

    it 'matches nested structures' do
      case record
      in { preferences: { notes: [{ body: String => body }, *] } }
        expect(body).to eq('hello')
      end
    end

    it 'does not match an absent attribute' do
      result = case record
               in { nope: _ } then :matched
               else :not_matched
               end
      expect(result).to eq(:not_matched)
    end

    it 'returns every attribute for a nil key list' do
      expect(record.deconstruct_keys(nil)).to eq(record.attributes)
    end

    it 'returns only the requested keys' do
      expect(record.deconstruct_keys([:name])).to eq(name: 'Support')
    end
  end

  describe 'equality' do
    it 'is the same record as another of its class carrying the same id' do
      expect(record).to eq(record_class.new('id' => 1, 'name' => 'Renamed since'))
    end

    it 'is not the same record as one with a different id' do
      expect(record).not_to eq(record_class.new('id' => 2, 'name' => 'Support'))
    end

    it 'is not the same record as one of another class with the same id' do
      expect(record).not_to eq(Class.new(record_class).new('id' => 1))
    end

    it 'is not equal to something that is not a record' do
      expect(record).not_to eq('id' => 1)
    end

    it 'answers #eql? too, so a record can be a Hash key' do
      expect({ record => :found }[record_class.new('id' => 1)]).to eq(:found)
    end

    it 'hashes equal records alike' do
      expect(record.hash).to eq(record_class.new('id' => 1).hash)
    end

    it 'deduplicates equal records' do
      expect([record, record_class.new('id' => 1)].uniq.size).to eq(1)
    end

    it 'collects equal records into one Set member' do
      expect(Set[record, record_class.new('id' => 1)].size).to eq(1)
    end

    context 'without an id' do
      subject(:unsaved) { record_class.new('name' => 'Support') }

      it 'is still itself, so it can be found again as a Hash key' do
        expect({ unsaved => :found }[unsaved]).to eq(:found)
      end

      it 'is not equal to an identical record, which is still a second record' do
        expect(unsaved).not_to eq(record_class.new('name' => 'Support'))
      end

      it 'is kept apart from an identical record' do
        expect([unsaved, record_class.new('name' => 'Support')].uniq.size).to eq(2)
      end
    end
  end

  describe 'serialization' do
    it 'renders the attributes as a JSON object' do
      expect(JSON.parse(record.to_json))
        .to eq('id' => 1, 'name' => 'Support', 'preferences' => { 'notes' => [{ 'body' => 'hello' }] })
    end

    it 'renders as its attributes when nested in a structure being generated' do
      expect(JSON.parse(JSON.generate(group: record))['group']).to include('name' => 'Support')
    end

    it 'carries the generator state, so pretty printing reaches the attributes' do
      expect(JSON.pretty_generate(record)).to include("\n")
    end

    it 'exposes the attributes to an encoder through #as_json' do
      expect(record.as_json).to eq(record.to_h)
    end

    it 'hands #as_json a copy rather than the frozen attributes' do
      expect(record.as_json).not_to be_frozen
    end
  end

  it 'rejects writes by default' do
    expect { record.name = 'other' }.to raise_error(NoMethodError, /read-only/)
  end
end
