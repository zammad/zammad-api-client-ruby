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

    it 'raises NoMethodError for an attribute the record does not carry' do
      expect { record.custom_field }.to raise_error(NoMethodError, /undefined method 'custom_field'/)
    end

    it 'raises NoMethodError for a reader given arguments' do
      expect { record.name('Other') }.to raise_error(NoMethodError, /undefined method 'name'/)
    end

    it 'still reads an attribute the record carries but Zammad left nil' do
      expect(record_class.new('note' => nil).note).to be_nil
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

    it 'supports a block' do
      expect(record.fetch(:nope) { |key| "no #{key}" }).to eq('no nope')
    end
  end

  describe '#[]=' do
    it 'goes through the same refusal a named writer does on a read-only record' do
      expect { record[:note] = 'x' }.to raise_error(NoMethodError, /attributes are read-only/)
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
  end

  describe 'pattern matching' do
    it 'matches on attribute values' do
      result = case record
               in { name: 'Support' } then :matched
               else :not_matched
               end
      expect(result).to eq(:matched)
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

    it 'answers #eql? too, so a record can be a Hash key' do
      expect({ record => :found }[record_class.new('id' => 1)]).to eq(:found)
    end

    it 'hashes equal records alike' do
      expect(record.hash).to eq(record_class.new('id' => 1).hash)
    end

    context 'without an id' do
      subject(:unsaved) { record_class.new('name' => 'Support') }

      it 'is still itself, so it can be found again as a Hash key' do
        expect({ unsaved => :found }[unsaved]).to eq(:found)
      end

      it 'is not equal to an identical record, which is still a second record' do
        expect(unsaved).not_to eq(record_class.new('name' => 'Support'))
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
  end

  it 'rejects writes by default' do
    expect { record.name = 'other' }.to raise_error(NoMethodError, /read-only/)
  end
end
