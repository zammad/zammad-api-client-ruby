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

  # Psych tags a subclass of Hash with its class and refuses to load a tag
  # it was not told of, so the YAML of a record's attributes would not load.
  it 'is written to YAML as the mapping a Hash is, and loads as one' do
    expect(attributes.to_yaml).to eq(plain.to_yaml)
    expect(YAML.load(attributes.to_yaml, permitted_classes: [Symbol])).to eq(plain)
  end
end
