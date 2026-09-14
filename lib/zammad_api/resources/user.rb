# frozen_string_literal: true

require_relative 'base'

module ZammadAPI
  module Resources
    class User < Base
      path 'api/v1/users'

      # UsersController#index hardcodes `reorder(id: :asc)`, so it honours
      # nothing but the paging - not even sort_by.
      INDEX_QUERY_KEYS = [].freeze

      SEARCHABLE = true

      belongs_to :organization, class_name: 'Organization'
    end
  end
end
