require 'zammad_api/log'
require 'zammad_api/transport'
require 'zammad_api/dispatcher'
require 'zammad_api/resources'

module ZammadAPI

  class Client

    def initialize(config)
      @internal_config = config
      @logger = ZammadAPI::Log.new(@internal_config)
      @transport = ZammadAPI::Transport.new(@internal_config, @logger)
      check_config
    end

    def method_missing(method, *_args)
      method = method.to_s
      class_name = "ZammadAPI::Resources::#{modulize(method)}"
      begin
        class_object = Kernel.const_get(class_name)
      rescue
        raise "Resource for #{method} does not exist"
      end
      ZammadAPI::Dispatcher.new(@transport, class_object)
    end

    private

    def check_config
      raise 'url is needed' if !@internal_config[:url]
      raise 'url need to start with http:// or https://' if @internal_config[:url] !~ %r{^(http|https)://}
      raise 'user is empty' if !@internal_config[:user] || @internal_config[:user].empty?
      raise 'password is empty' if !@internal_config[:password] || @internal_config[:password].empty?
    end

    def modulize(string)
      string.gsub(/__(.?)/) { "::#{$1.upcase}" }
            .gsub(%r{/(.?)}) { "::#{$1.upcase}" }
            .gsub(/(?:_+|-+)([a-z])/) { $1.upcase }
            .gsub(/(\A|\s)([a-z])/) { $1 + $2.upcase }
    end

  end

end
