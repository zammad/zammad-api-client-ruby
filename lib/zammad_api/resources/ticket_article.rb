class ZammadAPI::Resources::TicketArticle < ZammadAPI::Resources::Base
  url '/api/v1/ticket_articles'

  def attachments
    @attributes[:attachments].collect { |raw|
      raw[:ticket_id]  = @attributes[:ticket_id]
      raw[:article_id] = @attributes[:id]
      ZammadAPI::Resources::TicketArticleAttachment.new(@transport, raw)
    }
  end

end
