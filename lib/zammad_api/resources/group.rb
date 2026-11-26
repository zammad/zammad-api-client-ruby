# frozen_string_literal: true

module ZammadAPI
  module Resources
    class Group < Base
      path 'api/v1/groups'

      searchable true
    end
  end
end
