require 'spec_helper'

describe ZammadAPI do
  describe ZammadAPI::Error do
    it 'descends from RuntimeError' do
      expect(described_class.ancestors).to include(RuntimeError)
    end
  end

  describe ZammadAPI::ConfigurationError do
    it 'descends from ZammadAPI::Error' do
      expect(described_class.ancestors).to include(ZammadAPI::Error)
    end

    it 'descends from RuntimeError' do
      expect(described_class.ancestors).to include(RuntimeError)
    end
  end

  describe ZammadAPI::ResourceNotFoundError do
    it 'descends from ZammadAPI::Error' do
      expect(described_class.ancestors).to include(ZammadAPI::Error)
    end

    it 'descends from RuntimeError' do
      expect(described_class.ancestors).to include(RuntimeError)
    end
  end

  describe ZammadAPI::ResponseError do
    let(:fake_response) { Struct.new(:status, :body) }

    describe '.from' do
      it 'returns a ClientError for 4xx responses' do
        response = fake_response.new(404, '{}')
        expect(described_class.from(response, operation: 'find object')).to be_a(ZammadAPI::ClientError)
      end

      it 'returns a ClientError for 408 (Request Timeout)' do
        response = fake_response.new(408, '{}')
        expect(described_class.from(response, operation: 'find object')).to be_a(ZammadAPI::ClientError)
      end

      it 'returns a ClientError for 429 (Too Many Requests)' do
        response = fake_response.new(429, '{}')
        expect(described_class.from(response, operation: 'find object')).to be_a(ZammadAPI::ClientError)
      end

      it 'returns a ServerError for 5xx responses' do
        response = fake_response.new(500, '{}')
        expect(described_class.from(response, operation: 'find object')).to be_a(ZammadAPI::ServerError)
      end

      it 'returns a ServerError for 502 (Bad Gateway)' do
        response = fake_response.new(502, '<html>Bad Gateway</html>')
        expect(described_class.from(response, operation: 'find object')).to be_a(ZammadAPI::ServerError)
      end

      it 'returns a base ResponseError when no response is supplied' do
        result = described_class.from(nil, operation: 'find object')
        expect(result.class).to eq(described_class)
      end
    end

    describe 'subclasses' do
      it 'ClientError descends from ResponseError' do
        expect(ZammadAPI::ClientError.ancestors).to include(described_class)
      end

      it 'ServerError descends from ResponseError' do
        expect(ZammadAPI::ServerError.ancestors).to include(described_class)
      end

      it 'descends from ZammadAPI::Error' do
        expect(described_class.ancestors).to include(ZammadAPI::Error)
      end

      it 'descends from RuntimeError' do
        expect(described_class.ancestors).to include(RuntimeError)
      end
    end

    describe '#message' do
      it "uses the JSON body's 'error' key when present" do
        response = fake_response.new(404, '{"error":"User not found"}')
        error = described_class.from(response, operation: 'find object', resource_class: ZammadAPI::Resources::User)
        expect(error.message).to eq("Can't find object (ZammadAPI::Resources::User): User not found")
      end

      it 'preserves the original message format for the JSON-with-error case' do
        response = fake_response.new(422, '{"error":"name can\'t be blank"}')
        error = described_class.from(response, operation: 'save object', resource_class: ZammadAPI::Resources::Group)
        expect(error.message).to eq("Can't save object (ZammadAPI::Resources::Group): name can't be blank")
      end

      it 'falls back to HTTP status when the body is not JSON (issue #29 scenario)' do
        response = fake_response.new(502, '<html><body>Bad Gateway</body></html>')
        error = described_class.from(response, operation: 'find object', resource_class: ZammadAPI::Resources::User)
        expect(error.message).to eq("Can't find object (ZammadAPI::Resources::User): HTTP 502")
      end

      it 'falls back to HTTP status when the body is empty' do
        response = fake_response.new(500, '')
        error = described_class.from(response, operation: 'destroy object', resource_class: ZammadAPI::Resources::User)
        expect(error.message).to eq("Can't destroy object (ZammadAPI::Resources::User): HTTP 500")
      end

      it "falls back to HTTP status when the JSON body has no 'error' key" do
        response = fake_response.new(400, '{"foo":"bar"}')
        error = described_class.from(response, operation: 'find object', resource_class: ZammadAPI::Resources::User)
        expect(error.message).to eq("Can't find object (ZammadAPI::Resources::User): HTTP 400")
      end

      it 'omits the resource_class segment when none is supplied' do
        response = fake_response.new(404, '{"error":"nope"}')
        error = described_class.from(response, operation: 'find object')
        expect(error.message).to eq("Can't find object: nope")
      end

      it 'does not attach the JSON parser error as cause (it is a symptom, not the cause)' do
        response = fake_response.new(502, '<html>Bad Gateway</html>')
        error = described_class.from(response, operation: 'find object')
        expect(error.cause).to be_nil
      end
    end

    describe 'accessors' do
      let(:response) { fake_response.new(404, '{"error":"nope"}') }
      let(:error) do
        described_class.from(response, operation: 'find object', resource_class: ZammadAPI::Resources::User)
      end

      it 'exposes the underlying response' do
        expect(error.response).to be(response)
      end

      it 'exposes the response status' do
        expect(error.status).to eq(404)
      end

      it 'exposes the response body' do
        expect(error.body).to eq('{"error":"nope"}')
      end

      it 'exposes the operation' do
        expect(error.operation).to eq('find object')
      end

      it 'exposes the resource_class' do
        expect(error.resource_class).to eq(ZammadAPI::Resources::User)
      end

      it 'returns nil for status when no response is supplied' do
        error = described_class.from(nil, operation: 'find object')
        expect(error.status).to be_nil
      end

      it 'returns nil for body when no response is supplied' do
        error = described_class.from(nil, operation: 'find object')
        expect(error.body).to be_nil
      end
    end
  end
end
