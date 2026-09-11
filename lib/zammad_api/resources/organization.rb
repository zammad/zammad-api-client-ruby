# frozen_string_literal: true

require_relative 'base'

module ZammadAPI
  module Resources
    class Organization < Base
      path 'api/v1/organizations'
    end
  end
end
