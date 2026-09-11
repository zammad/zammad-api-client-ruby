# frozen_string_literal: true

require_relative 'base'

module ZammadAPI
  module Resources
    class User < Base
      path 'api/v1/users'

      belongs_to :organization, class_name: 'Organization'
    end
  end
end
