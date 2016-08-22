module ZammadAPI
  class Log

    def initialize(config)
      return if !config[:logger]
      require 'logger'
      @logger = Logger.new($stderr)
      #@logger.level = Logger::WARN
      @logger.level = Logger::DEBUG
    end

    def method_missing(method, *args)
      return if !@logger
      @logger.send(method, args)
    end
  end
end
