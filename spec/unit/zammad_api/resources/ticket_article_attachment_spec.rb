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
  end

  it 'is read-only' do
    attachment = described_class.new(transport, id: 3)
    expect { attachment.filename = 'other.txt' }.to raise_error(NoMethodError, /read-only/)
  end

  describe '#inspect' do
    it 'summarizes the attachment' do
      attachment = described_class.new(transport, id: 3, filename: 'note.txt', size: '12')
      expect(attachment.inspect)
        .to eq('#<ZammadAPI::Resources::TicketArticleAttachment id=3 filename="note.txt" size="12">')
    end
  end
end
