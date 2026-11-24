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

  describe '#add_article' do
    it 'creates the article for this ticket' do
      stub = stub_request(:post, article_url)
        .with(query: { 'expand' => 'true' }, body: '{"body":"hello","ticket_id":42}')
        .to_return(json_response({ id: 9, body: 'hello', ticket_id: 42 }, status: 201))

      ticket.add_article(body: 'hello')
      expect(stub).to have_been_requested
    end

    it 'returns the created article' do
      stub_request(:post, article_url).with(query: hash_including({}))
        .to_return(json_response({ id: 9, body: 'hello' }, status: 201))

      expect(ticket.add_article(body: 'hello')).to be_a(ZammadAPI::Resources::TicketArticle)
    end

    it 'returns a persisted article' do
      stub_request(:post, article_url).with(query: hash_including({}))
        .to_return(json_response({ id: 9 }, status: 201))

      expect(ticket.add_article(body: 'hello')).to be_persisted
    end

    # `ticket.add_article(params.require(:article).permit(:body))`, which is
    # taken apart here before the article is built from it.
    it 'reads strong parameters as the Hash they convert to' do
      stub = stub_request(:post, article_url)
        .with(query: { 'expand' => 'true' }, body: '{"body":"hello","ticket_id":42}')
        .to_return(json_response({ id: 9, body: 'hello', ticket_id: 42 }, status: 201))

      ticket.add_article(StrongParameters.new(body: 'hello'))
      expect(stub).to have_been_requested
    end

    it 'uses its own id over a ticket_id in the attributes' do
      stub = stub_request(:post, article_url)
        .with(query: { 'expand' => 'true' }, body: '{"ticket_id":42,"body":"hello"}')
        .to_return(json_response({ id: 9, ticket_id: 42 }, status: 201))

      ticket.add_article(ticket_id: 9, body: 'hello')
      expect(stub).to have_been_requested
    end

    it 'leaves the Hash it was given as it was' do
      stub_request(:post, article_url).with(query: hash_including({}))
        .to_return(json_response({ id: 9, ticket_id: 42 }, status: 201))
      attributes = { ticket_id: 9, body: 'hello' }
      ticket.add_article(attributes)

      expect(attributes).to eq(ticket_id: 9, body: 'hello')
    end

    context 'when the ticket has not been saved' do
      subject(:ticket) { described_class.new(unit_transport, title: 'Help') }

      it 'refuses locally' do
        expect { ticket.add_article(body: 'hello') }.to raise_error(ZammadAPI::Error, /has no id, save it first/)
      end

      it 'sends nothing' do
        stub = stub_request(:post, article_url).with(query: hash_including({}))

        begin
          ticket.add_article(body: 'hello')
        rescue ZammadAPI::Error
          nil
        end

        expect(stub).not_to have_been_requested
      end
    end
  end

  describe '#article' do
    it 'is not a method of a ticket' do
      expect(described_class.method_defined?(:article)).to be(false)
    end

    it 'raises NoMethodError when called to add an article, and sends nothing' do
      expect { ticket.article(body: 'hello') }.to raise_error(NoMethodError)
      expect(a_request(:any, /zammad\.test/)).not_to have_been_made
    end

    it 'reads the article staged for the next save' do
      ticket.article = { body: 'reply' }

      expect(ticket.article).to eq(body: 'reply')
    end
  end
end
