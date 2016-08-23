module ZammadAPI
  class Dispatcher

    def initialize(transport, resource)
      @transport = transport
      @resource  = resource
    end

    def method_missing(method, *args)
      @resource.send(method, @transport, args[0])
    end
  end
end
