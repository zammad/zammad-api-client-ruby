# frozen_string_literal: true

module ZammadAPI
  module Resources
    class TicketArticle < Base
      path 'api/v1/ticket_articles'

      # @return [Array<TicketArticleAttachment>] the article's attachments
      def attachments
        (attributes[:attachments] || []).map do |raw|
          TicketArticleAttachment.new(transport, raw.merge(ticket_id: attributes[:ticket_id], article_id: id))
        end
      end
    end
  end
end
