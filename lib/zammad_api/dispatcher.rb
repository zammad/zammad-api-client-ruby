module ZammadAPI
  class Dispatcher

    def initialize(transport, resource)
      @resource = resource
      @transport = transport
    end

    def method_missing(method, *args)
      @resource.send(method, @transport, args[0])
    end
  end
end
