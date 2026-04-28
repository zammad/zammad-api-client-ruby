require 'spec_helper'

describe ZammadAPI::JsonHelper do
  subject(:helper) do
    Class.new { include ZammadAPI::JsonHelper }.new
  end

  describe '#safe_json_parse' do
    it 'parses valid JSON' do
      expect(helper.safe_json_parse('{"key":"value"}')).to eq('key' => 'value')
    end

    it 'returns empty hash for invalid JSON' do
      expect(helper.safe_json_parse('not json')).to eq({})
    end

    it 'returns empty hash for HTML responses' do
      expect(helper.safe_json_parse('<html><body>Bad Gateway</body></html>')).to eq({})
    end
  end
end
