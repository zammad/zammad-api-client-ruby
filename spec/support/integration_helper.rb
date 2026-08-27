# frozen_string_literal: true

require 'securerandom'

# Helpers for integration specs, which need a reachable Zammad instance.
class Helper
  def self.config
    {
      url:      ENV['TEST_URL']      || 'http://localhost:3000/',
      user:     ENV['TEST_USER']     || 'admin@example.com',
      password: ENV['TEST_PASSWORD'] || 'test'
    }
  end

  def self.client(**overrides)
    ZammadAPI::Client.new(**config, **overrides)
  end

  # Runs Zammad's auto wizard so that the instance has a known base state.
  def self.auto_wizard
    connection = Faraday.new(url: config[:url])
    response   = connection.get('api/v1/getting_started/auto_wizard')
    data       = JSON.parse(response.body)

    return true if data['auto_wizard_success']

    raise "Unable to start auto wizard: #{response.body}"
  end

  def self.random
    SecureRandom.random_number(99_999_999).to_s
  end
end
