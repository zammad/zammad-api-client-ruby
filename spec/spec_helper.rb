
require 'zammad_api'

class Helper

  def self.client(params = {})
    client = ZammadAPI::Client.new(
      url: params[:url] || config[:url],
      user: params[:user] || config[:user],
      password: params[:password] || config[:password],
    )
    client
  end

  def self.random
    rand(99_999_999).to_s
  end

  # start auto wizard
  def self.auto_wizard
    url = Helper.config[:url]
    conn = Faraday.new(url: url) do |faraday|
      #faraday.request  :url_encoded             # form-encode POST params
      #faraday.response :logger                  # log requests to STDOUT
      faraday.adapter Faraday.default_adapter  # make requests with Net::HTTP
    end

    url_auto_wizard = '/api/v1/getting_started/auto_wizard'
    response = conn.get url_auto_wizard
    data = JSON.parse(response.body)
    p "data: #{data.inspect}"
    raise "Unable to start auto wizard: #{response.body}" if data['auto_wizard_success'] != true
    true
  end

  def self.config
    {
      url: ENV['TEST_URL'] || 'http://localhost:3000/',
      user: ENV['TEST_USER'] || 'master@example.com',
      password: ENV['TEST_PASSWORD'] || 'test'
    }
  end

end
