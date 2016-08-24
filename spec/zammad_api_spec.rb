require 'spec_helper'
require 'authentication'

describe ZammadAPI do
  it 'has a version number' do
    expect(ZammadAPI::VERSION).not_to be nil
  end
end
