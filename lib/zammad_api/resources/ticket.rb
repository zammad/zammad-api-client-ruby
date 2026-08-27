# frozen_string_literal: true

require_relative 'base'
require_relative 'ticket_article'

module ZammadAPI
  module Resources
    class Ticket < Base
      path 'api/v1/tickets'

      # @return [Array<TicketArticle>] every article of this ticket
      # @raise [ResponseError] when Zammad rejected the request
      def articles
        response = transport.get(
          "api/v1/ticket_articles/by_ticket/#{id}",
          operation:      'get articles',
          resource_class: self.class,
          query:          { expand: true }
        )
        articles = response.decoded(:array, operation: 'get articles', resource_class: self.class)
        articles.map { TicketArticle.from_response(transport, it) }
      end

      # Adds an article to this ticket.
      #
      # @param attributes [Hash] article attributes, e.g. +body:+, +type:+
      # @return [TicketArticle] the created article
      # @raise [ResponseError] when Zammad rejected the request
      def article(attributes = {})
        record = TicketArticle.new(transport, attributes.merge(ticket_id: id))
        record.save
        record
      end
    end
  end
end
