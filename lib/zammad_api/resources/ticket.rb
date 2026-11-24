# frozen_string_literal: true

require_relative 'base'
require_relative 'ticket_article'

module ZammadAPI
  module Resources
    class Ticket < Base
      path 'api/v1/tickets'

      # TicketsController#index hardcodes `reorder(id: :asc)`, so it reads nothing
      # but the paging - not even sort_by.
      sortable false

      # /api/v1/tickets caps the page size at 100, unlike the generic index
      # endpoints, see TicketsController#index.
      max_per_page 100

      searchable true

      belongs_to :customer,     class_name: 'User'
      belongs_to :owner,        class_name: 'User'
      belongs_to :organization, class_name: 'Organization'
      belongs_to :group,        class_name: 'Group'
      belongs_to :state,        class_name: 'TicketState'
      belongs_to :priority,     class_name: 'TicketPriority'

      has_many :articles, class_name: 'TicketArticle', path: ->(id) { "api/v1/ticket_articles/by_ticket/#{id}" }

      # Every article of this ticket, refetched on each call: the same list as
      # +ticket.related.articles+.
      #
      # @return [Array<TicketArticle>]
      # @raise [ResponseError] when Zammad rejected the request
      def articles = related.articles

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
