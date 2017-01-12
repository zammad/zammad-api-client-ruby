module ZammadAPI
  class ListBase
    include Enumerable

    def initialize(resource, transport, parameter = {})
      @resource  = resource
      @url       = @resource.get_url
      @transport = transport
      @parameter = {
        page:     1,
        per_page: 10,
        expand:   'true',
      }.merge(parameter)
    end

    def [](position)

      local_parameter = @parameter.merge(
        page:     position + 1,
        per_page: 1
      )
      perform_request(local_parameter)[0]
    end

    def page(page, per_page, &block)

      @parameter[:page]     = page
      @parameter[:per_page] = per_page
      fetch_and_yield_each(&block)
    end

    def page_next(&block)
      @parameter[:page] += 1
      fetch_and_yield_each(&block)
    end

    def page_prev(&block)
      @parameter[:page] -= 1
      fetch_and_yield_each(&block)
    end

    def each(&block)
      fetch_and_yield_each(&block)
    end

    private

    def fetch_and_yield_each
      result = perform_request(@parameter)
      result.each { |item|
        yield item
      }
    end

    def request(request, url, parameter)

      # convert parameters into a GET query
      url += '?' + parameter.map { |key, value|

        if !value.is_a? String
          value = value.to_s
        end

        "#{key}=#{CGI.escape value}"
      }.join('&')

      response = @transport.get(url: url)
      data = JSON.parse(response.body)
      if response.status != 200
        raise "Can't get .#{request} of object (#{@resource.class.name}): #{data['error']}"
      end

      list = []
      data.each { |local_data|
        item = @resource.new(@transport, local_data)
        item.new_instance = false
        list.push item
      }
      list
    end

    def perform_request(_parameter)
      raise "no perform_request implementation for #{self.class.name} found"
    end
  end
end
