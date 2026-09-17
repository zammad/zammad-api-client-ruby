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

  describe 'once destroyed' do
    let(:ticket_url) { "#{ClientHelper::BASE_URL}api/v1/tickets/42" }

    before do
      stub_request(:delete, ticket_url).with(query: hash_including({})).to_return(json_response({}))
      ticket.destroy
    end

    # Each of these says what the caller gets, not which ivar was cleared.
    # `destroy` dropped the `related` memo and was taken to have closed this,
    # but the reader rebuilt one on the next call, so every path below went
    # on reaching a ticket that is gone.
    it 'refuses the articles reader rather than fetching a deleted ticket' do
      expect { ticket.articles }.to raise_error(ZammadAPI::Error, /was destroyed/)
    end

    it 'refuses the related proxy' do
      expect { ticket.related }.to raise_error(ZammadAPI::Error, /was destroyed/)
    end

    it 'refuses to add an article rather than POSTing a dead ticket_id' do
      expect { ticket.article(body: 'hello') }.to raise_error(ZammadAPI::Error, /was destroyed/)
    end

    it 'makes no request at all when an article is refused' do
      stub = stub_request(:post, article_url).with(query: hash_including({}))
      begin
        ticket.article(body: 'hello')
      rescue ZammadAPI::Error # rubocop:disable Lint/SuppressedException
      end

      expect(stub).not_to have_been_requested
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

    # An article belongs to a ticket by id. Unchecked, this POSTed
    # `ticket_id: null` and left the caller reading Zammad's 422 to work out
    # that the ticket had never been saved.
    context 'when the ticket has not been saved' do
      subject(:ticket) { described_class.new(unit_transport, title: 'Help') }

      it 'refuses locally' do
        expect { ticket.article(body: 'hello') }.to raise_error(ZammadAPI::Error, /has no id, save it first/)
      end

      it 'sends nothing' do
        stub = stub_request(:post, article_url).with(query: hash_including({}))

        begin
          ticket.article(body: 'hello')
        rescue ZammadAPI::Error
          nil
        end

        expect(stub).not_to have_been_requested
      end
    end
  end
end
