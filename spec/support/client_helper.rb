# frozen_string_literal: true

# Helpers for unit specs, which talk to WebMock stubs instead of a Zammad.
module ClientHelper
  BASE_URL = 'http://zammad.test/'

  # Retries are disabled by default so that specs exercising error paths do
  # not wait for the backoff intervals.
  def unit_config(**overrides)
    { url: BASE_URL, http_token: 'test-token', retries: 0 }.merge(overrides)
  end

  def unit_client(**overrides)
    ZammadAPI::Client.new(**unit_config(**overrides))
  end

  def unit_transport(**overrides)
    ZammadAPI::Transport.new(ZammadAPI::Config.new(**unit_config(**overrides)))
  end

  # @return [Hash] arguments for WebMock's +to_return+ with a JSON body
  def json_response(body, status: 200, headers: {})
    {
      status:  status,
      body:    JSON.generate(body),
      headers: { 'Content-Type' => 'application/json' }.merge(headers)
    }
  end
end
