# frozen_string_literal: true

RSpec.describe ZammadAPI::Response do
  def build(status: 200, body: { a: 1 }, raw_body: '{"a":1}', headers: {})
    described_class.new(status: status, headers: headers, body: body, raw_body: raw_body)
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

  describe '#json?' do
    it 'is true when the body was decoded' do
      expect(build).to be_json
    end

    it 'is false when the body is the untouched raw body' do
      raw = '<html></html>'
      expect(build(body: raw, raw_body: raw)).not_to be_json
    end
  end

  it 'is immutable' do
    expect(build).to be_frozen
  end
end
