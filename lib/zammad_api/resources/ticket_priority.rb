# frozen_string_literal: true

module ZammadAPI
  module Resources
    # A ticket priority, such as "2 normal". Reached through
    # {Client#ticket_priorities}.
    class TicketPriority < Base
      path 'api/v1/ticket_priorities'
    end
  end
end
