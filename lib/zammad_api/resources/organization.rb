# frozen_string_literal: true

module ZammadAPI
  module Resources
    class Organization < Base
      path 'api/v1/organizations'

      searchable true
    end
  end
end
