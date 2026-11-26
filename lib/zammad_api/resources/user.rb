# frozen_string_literal: true

module ZammadAPI
  module Resources
    class User < Base
      path 'api/v1/users'

      # UsersController#index hardcodes `reorder(id: :asc)`, so it reads nothing
      # but the paging - not even sort_by.
      sortable false

      searchable true
    end
  end
end
