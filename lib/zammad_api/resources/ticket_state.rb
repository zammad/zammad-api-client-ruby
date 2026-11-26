# frozen_string_literal: true

module ZammadAPI
  module Resources
    # A ticket state, such as "open". Reached through {Client#ticket_states}.
    class TicketState < Base
      path 'api/v1/ticket_states'
    end
  end
end
