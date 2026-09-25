# frozen_string_literal: true

require_relative 'base'
require_relative 'ticket_article'

module ZammadAPI
  module Resources
    class Ticket < Base
      path 'api/v1/tickets'

      # TicketsController#index hardcodes `reorder(id: :asc)`, so it honours
      # nothing but the paging - not even sort_by.
      index_query_keys

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
      # @raise [Error] when the ticket has no id yet, or was destroyed
      # @raise [ResponseError] when Zammad rejected the request
      def article(attributes = {})
        # A destroyed ticket takes no articles, and says so here rather than
        # one request later. `require_id!` passes on its own, because destroy
        # leaves the id readable, so without this the POST went out naming a
        # ticket that is gone and Zammad's 422 about ticket_id was the first
        # news of it - the fourth state-changing path, after the three that
        # already ask.
        raise_if_destroyed!('add an article to')

        # An article belongs to a ticket by id, so ask for one here rather
        # than merging nil. Unchecked, this POSTed `ticket_id: null` and left
        # the caller reading Zammad's 422 to work out that the ticket they
        # were adding to had never been saved - the one path in the gem that
        # needed a stored id and went to the server to find out it had none.
        record = TicketArticle.new(transport, attributes.merge(ticket_id: require_id!))
        record.save!
        record
      end
    end
  end
end
