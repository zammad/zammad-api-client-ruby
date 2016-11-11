require 'faraday'
require 'openssl'

module ZammadAPI
  class Transport

    attr_accessor :url, :user, :password

    def initialize(config, logger)
      @logger = logger
      @logger.debug "Transport to #{config[:url]} with #{config[:user]}:#{config[:password]}"
      @conn = Faraday.new(url: config[:url]) do |faraday|
        #faraday.request  :url_encoded             # form-encode POST params
        #faraday.response :logger                  # log requests to STDOUT
        faraday.adapter Faraday.default_adapter  # make requests with Net::HTTP
      end
      @conn.headers[:user_agent] = 'Zammad API Ruby'
      if config[:http_token] && !config[:http_token].empty?
        @conn.token_auth(config[:http_token])
      elsif config[:oauth2_token] && !config[:oauth2_token].empty?
        @conn.authorization :Bearer, config[:oauth2_token]
      else
        @conn.basic_auth(config[:user], config[:password])
      end
    end

    def get(param)
      @logger.debug "GET: #{@url}#{param[:url]}"
      response = @conn.get param[:url]
      response
    end

    def post(param)
      @logger.debug "POST: #{@url}#{param[:url]}"
      @logger.debug "Params: #{param[:params].inspect}"
      response = @conn.post do |req|
        req.url param[:url]
        req.headers['Content-Type'] = 'application/json'
        req.body = param[:params].to_json
      end
      @logger.debug "Response: #{response.body}"
      response
    end

    def put(param)
      @logger.debug "PUT: #{@url}#{param[:url]}"
      @logger.debug "Params: #{param[:params].inspect}"
      response = @conn.put do |req|
        req.url param[:url]
        req.headers['Content-Type'] = 'application/json'
        req.body = param[:params].to_json
      end
      @logger.debug "Response: #{response.body}"
      response
    end

    def delete(param)
      @logger.debug "DELETE: #{@url}#{param[:url]}"
      response = @conn.delete param[:url]
      @logger.debug "Response: #{response.body}"
      response
    end

  end
end
