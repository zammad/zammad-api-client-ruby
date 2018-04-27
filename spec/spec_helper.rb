$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

# we don't require 'webmock/rspec' over here
# since we want to mock only certain requests
# but the API should be available in general
require 'webmock'

RSpec.configure do |config|
  config.include WebMock::API
  config.include WebMock::Matchers
end

require 'zammad_api'

class Helper

  def self.config
    {
      url:      ENV['TEST_URL']      || 'http://localhost:3000/',
      user:     ENV['TEST_USER']     || 'master@example.com',
      password: ENV['TEST_PASSWORD'] || 'test'
    }
  end

  def self.client(params = {})
    ZammadAPI::Client.new(
      url:      params[:url]      || config[:url],
      user:     params[:user]     || config[:user],
      password: params[:password] || config[:password],
    )
  end

  # start auto wizard
  def self.auto_wizard
    conn = Faraday.new(url: config[:url] ) do |faraday|
      faraday.adapter Faraday.default_adapter  # make requests with Net::HTTP
    end

    url_auto_wizard = '/api/v1/getting_started/auto_wizard'
    response        = conn.get url_auto_wizard
    data            = JSON.parse(response.body)

    return true if data['auto_wizard_success']

    raise "Unable to start auto wizard: #{response.body}"
  end

  def self.random
    rand(99_999_999).to_s
  end
end
