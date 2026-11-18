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
      # and +group_ids+ to the agents with access to those groups - full
      # access where it is a list of ids, the access named for each group
      # where it is a Hash. See {ResourceProxy#search}, also for what
      # +permissions+ does not narrow where Zammad searches through
      # Elasticsearch.
      search_filters :role_ids, :group_ids, :permissions

      belongs_to :organization, class_name: 'Organization'
    end
  end
end
