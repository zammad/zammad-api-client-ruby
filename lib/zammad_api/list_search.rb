require 'zammad_api/list_base'

module ZammadAPI
  class ListSearch < ListBase

    private

    def perform_request(parameter)
      request('search', "#{@url}/search", parameter)
    end
  end
end
