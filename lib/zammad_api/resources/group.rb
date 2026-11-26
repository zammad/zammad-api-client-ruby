# frozen_string_literal: true

module ZammadAPI
  module Resources
    # A group: what a ticket is assigned to, and what agents are given access by.
    # Reached through {Client#groups}.
    class Group < Base
      path 'api/v1/groups'

      searchable true
    end
  end
end
