# frozen_string_literal: true

require_relative 'base'
require_relative 'ticket_article_attachment'

module ZammadAPI
  module Resources
    class TicketArticle < Base
      path 'api/v1/ticket_articles'

      # @return [Array<TicketArticleAttachment>] the article's attachments
      def attachments
        list = attributes[:attachments] || []
        list.map do |raw|
          TicketArticleAttachment.new(
            transport,
            raw.merge(ticket_id: attributes[:ticket_id], article_id: id)
          )
        end
      end
    end
  end
end
