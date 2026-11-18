# frozen_string_literal: true

require_relative 'base'

module ZammadAPI
  module Resources
    class User < Base
      path 'api/v1/users'

      # UsersController#index hardcodes `reorder(id: :asc)`, so it reads nothing
      # but the paging - not even sort_by.
      sortable false

      searchable true

      # User::Search is the one search that reads these: it joins the roles
      # for +role_ids+, resolves +permissions+ to the roles that carry them,
      # and +group_ids+ to the users with access to those groups.
      search_filters :role_ids, :group_ids, :permissions

      belongs_to :organization, class_name: 'Organization'
    end
  end
end
