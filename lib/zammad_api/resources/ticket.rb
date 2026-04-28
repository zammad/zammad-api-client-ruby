class ZammadAPI::Resources::Ticket < ZammadAPI::Resources::Base
  url '/api/v1/tickets'

  def articles
    response = @transport.get(url: "/api/v1/ticket_articles/by_ticket/#{id}?expand=true")
    data = safe_json_parse(response.body)
    if response.status != 200
      raise "Can't get articles (#{self.class.name}): #{data['error']}"
    end

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
