# frozen_string_literal: true

RSpec.describe ZammadAPI::AttributeAccess do
  subject(:record) { record_class.new(attributes) }

  let(:record_class) do
    Class.new do
      include ZammadAPI::AttributeAccess

      def initialize(attributes)
        @attributes = deep_symbolize(attributes)
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

    it 'is true for any writer' do
      expect(record).to respond_to(:anything=)
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

  it 'rejects writes by default' do
    expect { record.name = 'other' }.to raise_error(NoMethodError, /read-only/)
  end
end
