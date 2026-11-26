# frozen_string_literal: true

module ZammadAPI
  module Resources
    # An organization that customers belong to. Reached through
    # {Client#organizations}.
    class Organization < Base
      path 'api/v1/organizations'

      searchable true
    end
  end
end
