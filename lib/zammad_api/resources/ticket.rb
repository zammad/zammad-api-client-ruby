# frozen_string_literal: true

require_relative 'base'
require_relative 'ticket_article'

module ZammadAPI
  module Resources
    class Ticket < Base
      path 'api/v1/tickets'

      # /api/v1/tickets caps the page size at 100, unlike the generic index
      # endpoints, see TicketsController#index.
      MAX_PER_PAGE = 100

      belongs_to :customer,     class_name: 'User'
      belongs_to :owner,        class_name: 'User'
      belongs_to :organization, class_name: 'Organization'
      belongs_to :group,        class_name: 'Group'
      belongs_to :state,        class_name: 'TicketState'
      belongs_to :priority,     class_name: 'TicketPriority'

      has_many :articles, class_name: 'TicketArticle', path: ->(ticket) { "api/v1/ticket_articles/by_ticket/#{ticket.id}" }

      # Every article of this ticket, refetched on each call.
      #
      # The same list as +ticket.related.articles+; this is the older name and
      # stays because it reads better than reaching through +related+ for the
      # one association a ticket is usually asked for.
      #
      # @return [Array<TicketArticle>]
      # @raise [ResponseError] when Zammad rejected the request
      def articles = related.articles

      # Adds an article to this ticket.
      #
      # @param attributes [Hash] article attributes, e.g. +body:+, +type:+
      # @return [TicketArticle] the created article
      # @raise [ResponseError] when Zammad rejected the request
      def article(attributes = {})
        record = TicketArticle.new(transport, attributes.merge(ticket_id: id))
        record.save!
        record
      end
    end
  end
end
