# frozen_string_literal: true

require_relative 'base'

module ZammadAPI
  module Resources
    class TicketPriority < Base
      path 'api/v1/ticket_priorities'
    end
  end
end
