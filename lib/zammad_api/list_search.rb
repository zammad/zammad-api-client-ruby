module ZammadAPI
  class ListSearch

    def initialize(transport, resource, data)
      @resource = resource
      @transport = transport
      @data = data
      @page = 1
      @per_page = 10
    end

    #def method_missing(method, *args, &block)
    #  p "method_missing #{method.inspect}/#{args.inspect}/#{block.inspect}"
    #end

    def [](position)
      @resource.search_fetch(@transport, @data, position + 1, 1)[0]
    end

    def page(page_number, per_page_number)
      @page = page_number
      @per_page = per_page_number
      result = @resource.search_fetch(@transport, @data, page_number, per_page_number)
      result.each {|item|
        yield item
      }
    end

    def page_next
      @page += 1
      result = @resource.search_fetch(@transport, @data, @page, @per_page)
      result.each {|item|
        yield item
      }
    end

    def page_prev
      @page -= 1
      result = @resource.search_fetch(@transport, @data, @page, @per_page)
      result.each {|item|
        yield item
      }
    end

    def each
      result = @resource.search_fetch(@transport, @data)
      result.each {|item|
        yield item
      }
    end

  end
end
