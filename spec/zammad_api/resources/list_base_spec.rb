require 'spec_helper'

describe ZammadAPI::ListBase do

  it 'is a Enumerable' do
    expect(described_class.ancestors).to include(Enumerable)
  end
end
