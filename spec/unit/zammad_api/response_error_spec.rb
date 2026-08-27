# frozen_string_literal: true

RSpec.describe ZammadAPI::ResponseError do
  def response(status, body, headers = {})
    ZammadAPI::Response.new(
      status:   status,
      headers:  headers,
      body:     body,
      raw_body: body.is_a?(String) ? body : JSON.generate(body)
    )
  end

  describe 'hierarchy' do
    {
      ZammadAPI::ConfigurationError   => ZammadAPI::Error,
      ZammadAPI::UnknownResourceError => ZammadAPI::Error,
      ZammadAPI::ParseError           => ZammadAPI::Error,
      ZammadAPI::ConnectionError      => ZammadAPI::TransportError,
      ZammadAPI::TimeoutError         => ZammadAPI::TransportError,
      ZammadAPI::ClientError          => described_class,
      ZammadAPI::ServerError          => described_class,
      ZammadAPI::AuthenticationError  => ZammadAPI::ClientError,
      ZammadAPI::AuthorizationError   => ZammadAPI::ClientError,
      ZammadAPI::NotFoundError        => ZammadAPI::ClientError,
      ZammadAPI::ValidationError      => ZammadAPI::ClientError,
      ZammadAPI::RateLimitError       => ZammadAPI::ClientError
    }.each do |error_class, parent|
      it "#{error_class} descends from #{parent}" do
        expect(error_class.ancestors).to include(parent)
      end
    end

    it 'roots every error at ZammadAPI::Error' do
      expect(ZammadAPI::TransportError.ancestors).to include(ZammadAPI::Error)
    end

    it 'roots ZammadAPI::Error at StandardError' do
      expect(ZammadAPI::Error.ancestors).to include(StandardError)
    end
  end

  describe '.build' do
    {
      401 => ZammadAPI::AuthenticationError,
      403 => ZammadAPI::AuthorizationError,
      404 => ZammadAPI::NotFoundError,
      422 => ZammadAPI::ValidationError,
      429 => ZammadAPI::RateLimitError,
      400 => ZammadAPI::ClientError,
      408 => ZammadAPI::ClientError,
      418 => ZammadAPI::ClientError,
      500 => ZammadAPI::ServerError,
      502 => ZammadAPI::ServerError,
      503 => ZammadAPI::ServerError
    }.each do |status, error_class|
      it "maps #{status} to #{error_class}" do
        result = described_class.build(response(status, {}), operation: 'find object')
        expect(result).to be_an_instance_of(error_class)
      end
    end

    it 'falls back to the base class without a response' do
      expect(described_class.build(nil, operation: 'find object')).to be_an_instance_of(described_class)
    end
  end

  describe '#message' do
    it "uses the body's error key" do
      error = described_class.build(
        response(404, { error: 'User not found' }),
        operation:      'find object',
        resource_class: ZammadAPI::Resources::User
      )
      expect(error.message).to eq("Can't find object (ZammadAPI::Resources::User): User not found")
    end

    it 'prefers error_human, which Zammad intends for end users' do
      error = described_class.build(
        response(422, { error: 'Validation failed', error_human: 'Name is required' }),
        operation: 'save object'
      )
      expect(error.message).to eq("Can't save object: Name is required")
    end

    it 'falls back to the status when the body is not JSON' do
      error = described_class.build(
        response(502, '<html><body>Bad Gateway</body></html>'),
        operation:      'find object',
        resource_class: ZammadAPI::Resources::User
      )
      expect(error.message).to eq("Can't find object (ZammadAPI::Resources::User): HTTP 502")
    end

    it 'falls back to the status when the body has no error key' do
      error = described_class.build(response(400, { foo: 'bar' }), operation: 'find object')
      expect(error.message).to eq("Can't find object: HTTP 400")
    end

    it 'falls back to the status when the error value is empty' do
      error = described_class.build(response(500, { error: '' }), operation: 'find object')
      expect(error.message).to eq("Can't find object: HTTP 500")
    end

    it 'reports a missing response' do
      expect(described_class.build(nil, operation: 'find object').message)
        .to eq("Can't find object: no response")
    end

    it 'omits the resource class when none was supplied' do
      error = described_class.build(response(404, { error: 'nope' }), operation: 'find object')
      expect(error.message).to eq("Can't find object: nope")
    end
  end

  describe 'accessors' do
    subject(:error) do
      described_class.build(
        response(404, { error: 'nope' }, 'x-request-id' => 'abc'),
        operation:      'find object',
        resource_class: ZammadAPI::Resources::User
      )
    end

    it 'exposes the status' do
      expect(error.status).to eq(404)
    end

    it 'exposes the decoded body' do
      expect(error.body).to eq({ error: 'nope' })
    end

    it 'exposes the headers' do
      expect(error.headers).to eq('x-request-id' => 'abc')
    end

    it 'exposes the operation' do
      expect(error.operation).to eq('find object')
    end

    it 'exposes the resource class' do
      expect(error.resource_class).to eq(ZammadAPI::Resources::User)
    end

    it 'exposes the server message' do
      expect(error.server_message).to eq('nope')
    end

    it 'returns nil accessors without a response' do
      bare = described_class.build(nil, operation: 'find object')
      expect([bare.status, bare.body, bare.headers, bare.server_message]).to eq([nil, nil, {}, nil])
    end
  end

  describe ZammadAPI::RateLimitError do
    it 'exposes Retry-After as an integer' do
      error = ZammadAPI::ResponseError.build(
        ZammadAPI::Response.new(status: 429, headers: { 'retry-after' => '30' }, body: {}, raw_body: '{}'),
        operation: 'find object'
      )
      expect(error.retry_after).to eq(30)
    end

    it 'returns nil when the header is absent' do
      error = ZammadAPI::ResponseError.build(
        ZammadAPI::Response.new(status: 429, headers: {}, body: {}, raw_body: '{}'),
        operation: 'find object'
      )
      expect(error.retry_after).to be_nil
    end

    it 'returns nil when the header is not a number' do
      error = ZammadAPI::ResponseError.build(
        ZammadAPI::Response.new(status: 429, headers: { 'retry-after' => 'later' }, body: {}, raw_body: '{}'),
        operation: 'find object'
      )
      expect(error.retry_after).to be_nil
    end
  end
end
