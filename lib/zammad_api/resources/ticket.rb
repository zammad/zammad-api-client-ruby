class ZammadAPI::Resources::Ticket < ZammadAPI::Resources::Base
  url '/api/v1/tickets'

  def articles
    response = @transport.get(url: "/api/v1/ticket_articles/by_ticket/#{id}?expand=true")
    if response.status != 200
      raise ZammadAPI::ResponseError.from(response, operation: 'get articles', resource_class: self.class)
    end

    data = safe_json_parse(response.body)

    data.collect do |raw|
      item = ZammadAPI::Resources::TicketArticle.new(@transport, raw)
      item.new_instance = false
      item
    end
  end

  def article(data)
    data[:ticket_id] = @attributes[:id]
    item = ZammadAPI::Resources::TicketArticle.new(@transport, data)
    item.save
    item
  end
end
