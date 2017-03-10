class ZammadAPI::Resources::TicketArticleAttachment < ZammadAPI::Resources::Base

  def initialize(transport, attributes = {})
    @transport  = transport
    @attributes = attributes
    symbolize_keys_deep!(@attributes)
  end

  def method_missing(method, *_args)
    @attributes[method.to_sym]
  end

  def download
    response = @transport.get(url: "/api/v1/ticket_attachment/#{ticket_id}/#{article_id}/#{id}")
    return response.body if response.status == 200
    data = JSON.parse(response.body)
    raise "Can't get articles (#{self.class.name}): #{data['error']}"
  end

end
