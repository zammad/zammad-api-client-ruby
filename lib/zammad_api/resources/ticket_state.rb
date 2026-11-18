# frozen_string_literal: true

require_relative 'base'

module ZammadAPI
  module Resources
    class TicketState < Base
      path 'api/v1/ticket_states'
    end
  end
end
