module ZammadAPI
  class ListAll

    def initialize(transport, resource)
      @transport = transport
      @resource = resource
      @page = 1
      @per_page = 10
    end

    #def method_missing(method, *args, &block)
    #  p "method_missing #{method.inspect}/#{args.inspect}/#{block.inspect}"
    #end

    def [](position)
      @resource.all_fetch(@transport, nil, position + 1, 1)[0]
    end

    def page(page_number, per_page_number)
      @page = page_number
      @per_page = per_page_number
      result = @resource.all_fetch(@transport, nil, page_number, per_page_number)
      result.each {|item|
        yield item
      }
    end

    def page_next
      @page += 1
      result = @resource.all_fetch(@transport, nil, @page, @per_page)
      result.each {|item|
        yield item
      }
    end

    def page_prev
      @page -= 1
      result = @resource.all_fetch(@transport, nil, @page, @per_page)
      result.each {|item|
        yield item
      }
    end

    def each
      result = @resource.all_fetch(@transport, nil)
      result.each {|item|
        yield item
      }
    end

  end
end
