# frozen_string_literal: true

module ZammadAPI
  module Resources
    # A ticket. Reached through {Client#tickets}, and its articles through
    # {#articles} and {#add_article}.
    class Ticket < Base
      path 'api/v1/tickets'

      # TicketsController#index hardcodes `reorder(id: :asc)`, so it reads nothing
      # but the paging - not even sort_by.
      sortable false

      # /api/v1/tickets caps the page size at 100, unlike the generic index
      # endpoints, see TicketsController#index.
      max_per_page 100

      searchable true

      # Every article of this ticket, read in one request on each call.
      #
      # @return [Array<TicketArticle>]
      # @raise [Error] when the ticket has no id yet
      # @raise [ResponseError] when Zammad rejected the request
      def articles
        path     = "#{TicketArticle.resource_path}/by_ticket/#{Transport.escape_path_segment(require_id!)}"
        response = transport.get(path, operation: 'get articles', resource_class: TicketArticle, query: { expand: true })

        response.decoded(:array, operation: 'get articles', resource_class: TicketArticle).map { TicketArticle.from_response(transport, it) }
      end

      # Adds an article to this ticket.
      #
      # @example
      #   ticket.add_article(subject: 'Update', body: 'Reset link sent.', type: 'note')
      #
      # @param attributes [Hash] article attributes, e.g. +body:+, +type:+
      # @return [TicketArticle] the created article
      # @raise [Error] when the ticket has no id yet
      # @raise [ResponseError] when Zammad rejected the request
      def add_article(attributes = {})
        record = TicketArticle.new(transport, Hash(attributes).merge(ticket_id: require_id!))
        record.save!
        record
      end
    end
  end
end
