# frozen_string_literal: true

require_relative 'base'

module ZammadAPI
  module Resources
    class Group < Base
      path 'api/v1/groups'

      SEARCHABLE = true
    end
  end
end
