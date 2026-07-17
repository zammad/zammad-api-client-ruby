require 'json'

module ZammadAPI
  class Error < RuntimeError; end

  class ConfigurationError < Error; end

  class ResourceNotFoundError < Error; end

  class ResponseError < Error
    attr_reader :response, :operation, :resource_class

    def initialize(operation:, response:, resource_class: nil)
      @operation      = operation
      @response       = response
      @resource_class = resource_class
      super(default_message)
    end

    def status
      response&.status
    end

    def body
      response&.body
    end

    def self.from(response, **kwargs)
      klass = if response.nil?
                self
              elsif response.status >= 500
                ServerError
              else
                ClientError
              end
      klass.new(response: response, **kwargs)
    end

    private

    def default_message
      subject = resource_class ? "#{operation} (#{resource_class.name})" : operation
      "Can't #{subject}: #{detail}"
    end

    def detail
      body_error || "HTTP #{status}"
    end

    def body_error
      return nil if body.to_s.strip.empty?

      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed['error'] : nil
    rescue JSON::ParserError
      nil
    end
  end

  class ClientError < ResponseError; end
  class ServerError < ResponseError; end
end
