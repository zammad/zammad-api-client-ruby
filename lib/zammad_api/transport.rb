require 'faraday'
require 'openssl'

module ZammadAPI
  class Transport

    attr_accessor :url, :user, :password, :on_behalf_of

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
        @conn.request :authorization, 'Token', config[:http_token]
      elsif config[:oauth2_token] && !config[:oauth2_token].empty?
        @conn.request :authorization, 'Bearer', config[:oauth2_token]
      else
        @conn.request :authorization, :basic, config[:user], config[:password]
      end
    end

    %w[get post put delete].each do |method|
      class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{method}(params)
          run_request(:#{method}, params)
        end
      RUBY
    end

    private

    def run_request(verb, param)

      @logger.debug "#{verb.to_s.upcase}: #{@url}#{param[:url]}"

      with_params = !param[:params].nil?
      if with_params
        @logger.debug "Params: #{param[:params].inspect}"
      end

      response = @conn.public_send(verb) do |req|
        req.url param[:url]

        if with_params
          req.headers['Content-Type'] = 'application/json'
          req.body                    = param[:params].to_json
        end

        if !on_behalf_of.nil?
          req.headers['X-On-Behalf-Of'] = on_behalf_of
        end

        yield(req) if block_given?
      end

      @logger.debug "Response: #{response.body}"
      response
    end
  end
end
