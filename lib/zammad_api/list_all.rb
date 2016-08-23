require 'zammad_api/list_base'

module ZammadAPI
  class ListAll < ListBase

    private

    def perform_request(parameter)
      request('all', @url, parameter)
    end
  end
end
