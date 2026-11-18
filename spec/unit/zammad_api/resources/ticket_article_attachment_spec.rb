# frozen_string_literal: true

RSpec.describe ZammadAPI::Resources::TicketArticleAttachment do
  let(:transport) { unit_transport }
  let(:download_url) { "#{ClientHelper::BASE_URL}api/v1/ticket_attachment/42/9/3" }

  describe 'built from an article' do
    subject(:attachment) { article.attachments.first }

    let(:article) do
      ZammadAPI::Resources::TicketArticle.from_response(
        transport,
        id:          9,
        ticket_id:   42,
        attachments: [{ id: 3, filename: 'note.txt', size: '12' }]
      )
    end

    it 'carries the attachment id' do
      expect(attachment.id).to eq(3)
    end

    it 'carries the filename' do
      expect(attachment.filename).to eq('note.txt')
    end

    it 'is given the ticket id, which the attachment endpoint needs' do
      expect(attachment.ticket_id).to eq(42)
    end

    it 'is given the article id' do
      expect(attachment.article_id).to eq(9)
    end

    it 'returns an empty list when the article has no attachments' do
      bare = ZammadAPI::Resources::TicketArticle.from_response(transport, id: 9)
      expect(bare.attachments).to eq([])
    end

    # This metadata comes off a response body like any other, and an element
    # that is not an object reached `raw.merge` and died there as a bare
    # NoMethodError from inside the gem - past the `rescue ZammadAPI::Error`
    # every caller is told to write.
    it 'refuses metadata that is not a list' do
      article = ZammadAPI::Resources::TicketArticle.from_response(transport, id: 9, attachments: 'none')

      expect { article.attachments }
        .to raise_error(ZammadAPI::ParseError, /expected a JSON array of objects, got String/)
    end

    it 'refuses a list holding something that is not an object' do
      article = ZammadAPI::Resources::TicketArticle.from_response(transport, id: 9, attachments: [3])

      expect { article.attachments }
        .to raise_error(ZammadAPI::ParseError, /got an array holding Integer/)
    end

    it 'names the article in the refusal' do
      article = ZammadAPI::Resources::TicketArticle.from_response(transport, id: 9, attachments: 'none')

      expect { article.attachments }
        .to raise_error(ZammadAPI::ParseError, /ZammadAPI::Resources::TicketArticle/)
    end
  end

  describe '#download' do
    subject(:attachment) { described_class.new(transport, id: 3, ticket_id: 42, article_id: 9) }

    it 'requests the attachment endpoint' do
      stub = stub_request(:get, download_url).to_return(status: 200, body: 'contents')
      attachment.download
      expect(stub).to have_been_requested
    end

    it 'returns the file contents' do
      stub_request(:get, download_url).to_return(status: 200, body: 'contents')
      expect(attachment.download).to eq('contents')
    end

    it 'returns binary data undisturbed' do
      png = "\x89PNG\r\n\x1A\n\x00\xFF".b
      stub_request(:get, download_url)
        .to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })

      expect(attachment.download).to eq(png)
    end

    it 'uses binary encoding' do
      stub_request(:get, download_url).to_return(status: 200, body: 'contents')
      expect(attachment.download.encoding).to eq(Encoding::BINARY)
    end

    it 'raises when the attachment is gone' do
      stub_request(:get, download_url).to_return(json_response({ error: 'not found' }, status: 404))
      expect { attachment.download }.to raise_error(ZammadAPI::NotFoundError)
    end

    it 'raises a helpful error when the metadata is incomplete' do
      expect { described_class.new(transport, id: 3).download }.to raise_error(KeyError)
    end

    it 'escapes a traversal in an id instead of reaching another endpoint' do
      stub = stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/ticket_attachment/1%2F..%2F..%2F..%2Fapi%2Fv1%2Fusers/9/3")
        .to_return(status: 200, body: 'contents')
      escaping = described_class.new(transport, id: 3, ticket_id: '1/../../../api/v1/users', article_id: 9)

      escaping.download

      expect(stub).to have_been_requested
      expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/9/3")).not_to have_been_made
    end

    it 'escapes the article id and the attachment id too' do
      stub = stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/ticket_attachment/42/9%2F..%2Fx/3%2F..%2Fy")
        .to_return(status: 200, body: 'contents')

      described_class.new(transport, id: '3/../y', ticket_id: 42, article_id: '9/../x').download

      expect(stub).to have_been_requested
    end
  end

  it 'is read-only' do
    attachment = described_class.new(transport, id: 3)
    expect { attachment.filename = 'other.txt' }.to raise_error(NoMethodError, /read-only/)
  end

  it 'does not claim a writer it would refuse' do
    expect(described_class.new(transport, id: 3)).not_to respond_to(:filename=)
  end

  describe '#inspect' do
    it 'summarizes the attachment' do
      attachment = described_class.new(transport, id: 3, filename: 'note.txt', size: '12')
      expect(attachment.inspect)
        .to eq('#<ZammadAPI::Resources::TicketArticleAttachment id=3 filename="note.txt" size="12">')
    end
  end
end
