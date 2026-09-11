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

    it 'returns nil for an unknown attribute, since Zammad allows custom fields' do
      expect(record.custom_field).to be_nil
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
