# frozen_string_literal: true

RSpec.describe ZammadAPI::Resources::Ticket do
  subject(:ticket) { described_class.from_response(unit_transport, id: 42, title: 'Help') }

  let(:articles_url) { "#{ClientHelper::BASE_URL}api/v1/ticket_articles/by_ticket/42" }
  let(:article_url) { "#{ClientHelper::BASE_URL}api/v1/ticket_articles" }

  describe '#articles' do
    it 'requests the articles of this ticket' do
      stub = stub_request(:get, articles_url).with(query: { 'expand' => 'true' }).to_return(json_response([]))
      ticket.articles
      expect(stub).to have_been_requested
    end

    it 'returns article records' do
      stub_request(:get, articles_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1, body: 'first' }, { id: 2, body: 'second' }]))

      expect(ticket.articles.map(&:body)).to eq(%w[first second])
    end

    it 'returns persisted articles' do
      stub_request(:get, articles_url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      expect(ticket.articles.first).to be_persisted
    end

    it 'raises ParseError when the response is not a list' do
      stub_request(:get, articles_url).with(query: hash_including({})).to_return(json_response({ id: 1 }))

      expect { ticket.articles }.to raise_error(ZammadAPI::ParseError, /expected a JSON array, got Hash/)
    end
  end

  describe '#article' do
    it 'creates the article for this ticket' do
      stub = stub_request(:post, article_url)
        .with(query: { 'expand' => 'true' }, body: '{"body":"hello","ticket_id":42}')
        .to_return(json_response({ id: 9, body: 'hello', ticket_id: 42 }, status: 201))

      ticket.article(body: 'hello')
      expect(stub).to have_been_requested
    end

    it 'returns the created article' do
      stub_request(:post, article_url).with(query: hash_including({}))
        .to_return(json_response({ id: 9, body: 'hello' }, status: 201))

      expect(ticket.article(body: 'hello')).to be_a(ZammadAPI::Resources::TicketArticle)
    end

    it 'returns a persisted article' do
      stub_request(:post, article_url).with(query: hash_including({}))
        .to_return(json_response({ id: 9 }, status: 201))

      expect(ticket.article(body: 'hello')).to be_persisted
    end
  end
end
