# frozen_string_literal: true

require 'pp'
require 'yaml'

RSpec.describe ZammadAPI::Attributes do
  subject(:attributes) { described_class[plain].freeze }

  let(:plain) { { login: 'jane', password: 'hunter2', preferences: { api_key: 'k', locale: 'de' } } }

  it 'is a Hash, and equal to one holding the same' do
    expect(attributes).to be_a(Hash).and eq(plain)
  end

  it 'reads every value as it is' do
    expect(attributes[:password]).to eq('hunter2')
  end

  it 'prints with the value under every key that names a credential blanked' do
    expect(attributes.inspect).to eq('{login: "jane", password: "[REDACTED]", preferences: {api_key: "[REDACTED]", locale: "de"}}')
  end

  it 'prints the same way where it is written into a String' do
    expect("#{attributes}").to eq(attributes.inspect) # rubocop:disable Style/RedundantInterpolation
  end

  # pp prints a Hash pair by pair and does not ask it for inspect. The width
  # keeps it on one line.
  it 'is printed the same way by pp' do
    expect(PP.pp(attributes, +'', 200)).to eq("#{attributes.inspect}\n")
  end

  # What Ruby raises for a write quotes the Hash, which is why this class is.
  it 'is quoted with its credentials blanked by the error for a write to it' do
    expect { attributes[:vip] = true }
      .to raise_error(FrozenError, %(can't modify frozen ZammadAPI::Attributes: #{attributes.inspect}))
  end

  it 'converts to a plain Hash, which prints what it holds' do
    expect(attributes.to_h).to be_an_instance_of(Hash).and(satisfy { it.inspect.include?('hunter2') })
  end

  it 'writes its values to JSON' do
    expect(JSON.generate(attributes)).to eq(JSON.generate(plain))
  end

  # Every Hash a record holds is of this class, whatever it is inside of.
  # Hash#to_h answers with a plain Hash holding what the receiver held, so
  # the conversion stopped at the first nested Hash.
  describe '#to_h' do
    subject(:attributes) { ZammadAPI::DeepCopy.frozen_copy(plain, symbolize_keys: true) }

    let(:plain) { { login: 'jane', preferences: { locale: 'de', devices: [{ name: 'phone' }] }, roles: [{ name: 'Agent' }] } }

    def classes_in(value)
      case value
      when Hash  then [value.class, *value.each_value.flat_map { classes_in(it) }]
      when Array then value.flat_map { classes_in(it) }
      else []
      end
    end

    it 'holds a Hash of this class at every depth to begin with' do
      expect(classes_in(attributes).uniq).to eq([described_class])
    end

    it 'is a plain Hash at every depth, inside an Array as well' do
      expect(classes_in(attributes.to_h).uniq).to eq([Hash])
    end

    it 'holds what the attributes hold' do
      expect(attributes.to_h).to eq(plain)
    end

    it 'is the caller\'s own to modify, down to a String' do
      copy = attributes.to_h
      copy[:preferences][:devices] << { name: 'tablet' }
      copy[:login] << '.doe'

      expect(attributes).to eq(plain)
    end

    it 'is the same for a Hash read out of the attributes' do
      expect(classes_in(attributes[:preferences].to_h).uniq).to eq([Hash])
    end

    it 'builds a plain Hash from the pairs a block answers, as Hash#to_h does' do
      expect(attributes.to_h { |key, _| [key.to_s, key.size] }).to eq('login' => 5, 'preferences' => 11, 'roles' => 5)
    end

    # The encoders that take the core types and nothing else go by the class
    # of the object, and name the one they refuse.
    context 'with a JSON encoder that takes nothing but the core types' do
      it 'is refused as it stands, by the name of its class' do
        expect { JSON.generate(attributes, strict: true) }
          .to raise_error(JSON::GeneratorError, /ZammadAPI::Attributes not allowed in JSON/)
      end

      it 'is written by JSON.generate with strict: true' do
        expect(JSON.generate(attributes.to_h, strict: true)).to eq(JSON.generate(plain))
      end

      it 'is written by a JSON::Coder' do
        expect(JSON::Coder.new.dump(attributes.to_h)).to eq(JSON.generate(plain))
      end
    end
  end

  # Psych tags a subclass of Hash with its class and refuses to load a tag
  # it was not told of, so the YAML of a record's attributes would not load.
  it 'is written to YAML as the mapping a Hash is, and loads as one' do
    expect(attributes.to_yaml).to eq(plain.to_yaml)
    expect(YAML.load(attributes.to_yaml, permitted_classes: [Symbol])).to eq(plain)
  end
end
