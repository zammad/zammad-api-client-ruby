# frozen_string_literal: true

RSpec.describe ZammadAPI::Associations::Proxy do
  subject(:ticket) { client.ticket.find(42) }

  let(:client) { unit_client }
  let(:ticket_url) { "#{ClientHelper::BASE_URL}api/v1/tickets/42" }
  let(:users_url) { "#{ClientHelper::BASE_URL}api/v1/users" }

  let(:ticket_attributes) do
    {
      id:          42,
      title:       'Help',
      customer:    'customer@example.com',
      customer_id: 7,
      state:       'open',
      state_id:    2,
      group:       'Users',
      group_id:    1
    }
  end

  before do
    stub_request(:get, ticket_url).with(query: hash_including({})).to_return(json_response(ticket_attributes))
  end

  describe 'belongs_to' do
    it 'fetches the whole record behind a foreign key' do
      stub_request(:get, "#{users_url}/7").with(query: { 'expand' => 'true' })
        .to_return(json_response({ id: 7, email: 'customer@example.com', firstname: 'Nicole' }))

      expect(ticket.related.customer.firstname).to eq('Nicole')
    end

    it 'returns the resource class of the target' do
      stub_request(:get, "#{users_url}/7").with(query: hash_including({})).to_return(json_response({ id: 7 }))

      expect(ticket.related.customer).to be_a(ZammadAPI::Resources::User)
    end

    it 'returns a persisted record' do
      stub_request(:get, "#{users_url}/7").with(query: hash_including({})).to_return(json_response({ id: 7 }))

      expect(ticket.related.customer).to be_persisted
    end

    it 'leaves the expanded attribute alone, so reading a name stays free' do
      expect(ticket.customer).to eq('customer@example.com')
      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).not_to have_been_made
    end

    it 'does not shadow an expanded attribute that names a state' do
      expect(ticket.state).to eq('open')
    end

    it 'is nil when the foreign key is not set' do
      stub_request(:get, ticket_url).with(query: hash_including({})).to_return(json_response({ id: 42 }))

      expect(ticket.related.customer).to be_nil
    end

    it 'makes no request when the foreign key is not set' do
      stub_request(:get, ticket_url).with(query: hash_including({})).to_return(json_response({ id: 42 }))

      ticket.related.customer
      expect(a_request(:get, %r{api/v1/users}).with(query: hash_including({}))).not_to have_been_made
    end

    it 'memoizes, so a loop does not refetch the same record' do
      stub_request(:get, "#{users_url}/7").with(query: hash_including({})).to_return(json_response({ id: 7 }))

      held = ticket
      3.times { held.related.customer }

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.once
    end

    it 'uses the declared foreign key rather than the association name' do
      stub = stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/ticket_states/2")
        .with(query: hash_including({}))
        .to_return(json_response({ id: 2, name: 'open' }))

      ticket.related.state
      expect(stub).to have_been_requested
    end

    it 'reaches the group resource' do
      stub = stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/groups/1")
        .with(query: hash_including({}))
        .to_return(json_response({ id: 1, name: 'Users' }))

      expect(ticket.related.group.name).to eq('Users')
      expect(stub).to have_been_requested
    end

    it 'propagates a failure to load the target' do
      stub_request(:get, "#{users_url}/7").with(query: hash_including({}))
        .to_return(json_response({ error: 'not found' }, status: 404))

      expect { ticket.related.customer }.to raise_error(ZammadAPI::NotFoundError)
    end
  end

  describe 'has_many' do
    let(:articles_url) { "#{ClientHelper::BASE_URL}api/v1/ticket_articles/by_ticket/42" }

    it 'fetches the list from the association endpoint' do
      stub_request(:get, articles_url).with(query: { 'expand' => 'true' })
        .to_return(json_response([{ id: 1, body: 'first' }]))

      expect(ticket.related.articles.map(&:body)).to eq(['first'])
    end

    it 'returns records of the target class' do
      stub_request(:get, articles_url).with(query: hash_including({})).to_return(json_response([{ id: 1 }]))

      expect(ticket.related.articles.first).to be_a(ZammadAPI::Resources::TicketArticle)
    end

    it 'is not memoized, so an article added afterwards shows up' do
      stub_request(:get, articles_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1 }]), json_response([{ id: 1 }, { id: 2 }]))

      held = ticket
      expect(held.related.articles.size).to eq(1)
      expect(held.related.articles.size).to eq(2)
    end

    it 'names the association in a parse failure' do
      stub_request(:get, articles_url).with(query: hash_including({})).to_return(json_response({ id: 1 }))

      expect { ticket.related.articles }
        .to raise_error(ZammadAPI::ParseError, /Can't get articles \(ZammadAPI::Resources::TicketArticle\)/)
    end

    # This is the one list in the gem read in a single request, because the
    # association endpoints Zammad routes serve the whole thing. An endpoint
    # that turned out to page would have handed back its first page with
    # nothing to say so, while `all` and `search` walk to the end.
    context 'when the endpoint answers with one page of several' do
      before do
        stub_request(:get, articles_url).with(query: hash_including({}))
          .to_return(json_response([{ id: 1 }, { id: 2 }], headers: { 'X-Total-Count' => '7' }))
      end

      it 'refuses rather than handing back a short list' do
        expect { ticket.related.articles }.to raise_error(ZammadAPI::PaginationError, /served 2 of 7 records/)
      end

      it 'names the association it could not read whole' do
        expect { ticket.related.articles }
          .to raise_error(ZammadAPI::PaginationError, /Can't get articles \(ZammadAPI::Resources::TicketArticle\)/)
      end
    end

    it 'accepts a list the endpoint reports in full' do
      stub_request(:get, articles_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1 }, { id: 2 }], headers: { 'X-Total-Count' => '2' }))

      expect(ticket.related.articles.size).to eq(2)
    end

    it 'accepts a list from an endpoint that reports no total at all' do
      stub_request(:get, articles_url).with(query: hash_including({}))
        .to_return(json_response([{ id: 1 }, { id: 2 }]))

      expect(ticket.related.articles.size).to eq(2)
    end

    it 'says to save an unsaved record rather than requesting a path without an id' do
      unsaved = ZammadAPI::Resources::Ticket.new(unit_transport, title: 'Help')

      expect { unsaved.related.articles }
        .to raise_error(ZammadAPI::Error, /has no id, so it has no articles to read; save it first/)
    end

    it 'escapes a traversal in the id instead of reaching another endpoint' do
      escaped = "#{ClientHelper::BASE_URL}api/v1/ticket_articles/by_ticket/1%2F..%2F..%2Fusers"
      stub = stub_request(:get, escaped).with(query: hash_including({})).to_return(json_response([]))
      escaping = ZammadAPI::Resources::Ticket.from_response(unit_transport, id: '1/../../users')

      escaping.related.articles

      expect(stub).to have_been_requested
      expect(a_request(:get, "#{ClientHelper::BASE_URL}api/v1/users").with(query: hash_including({})))
        .not_to have_been_made
    end
  end

  describe 'inheritance' do
    it 'gives every resource the stamps Zammad puts on every object' do
      expect(ZammadAPI::Resources::Group.associations.keys).to eq(%i[created_by updated_by])
    end

    it 'adds a resource its own associations on top' do
      expect(ZammadAPI::Resources::User.associations.keys).to include(:created_by, :organization)
    end

    it 'does not leak one resource\'s associations into another' do
      expect(ZammadAPI::Resources::Group.associations).not_to have_key(:customer)
    end

    it 'does not define another resource\'s reader on the proxy' do
      group = ZammadAPI::Resources::Group.from_response(unit_transport, id: 1)
      expect(group.related).not_to respond_to(:customer)
    end

    it 'raises NoMethodError for an association that was never declared' do
      expect { ticket.related.unicorn }.to raise_error(NoMethodError)
    end
  end

  describe 'the memo' do
    before do
      stub_request(:get, "#{users_url}/7").with(query: hash_including({})).to_return(json_response({ id: 7 }))
    end

    it 'is dropped by reload, because the foreign key may have moved' do
      held = ticket
      held.related.customer
      held.reload
      held.related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.twice
    end

    it 'is dropped by a save' do
      stub_request(:put, ticket_url).with(query: hash_including({})).to_return(json_response(ticket_attributes))

      held = ticket
      held.related.customer
      held.update!(title: 'Renamed')
      held.related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.twice
    end

    it 'is dropped when the foreign key it resolved from is written' do
      stub_request(:get, "#{users_url}/9").with(query: hash_including({}))
        .to_return(json_response({ id: 9, email: 'nine@example.com' }))

      held = ticket
      expect(held.related.customer.id).to eq(7)

      held.customer_id = 9

      expect(held.related.customer.id).to eq(9)
    end

    it 'survives a write to an attribute no association resolves through' do
      held = ticket
      held.related.customer
      held.title = 'Renamed'
      held.related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.once
    end

    it 'is dropped by assign_attributes touching a foreign key' do
      stub_request(:get, "#{users_url}/9").with(query: hash_including({}))
        .to_return(json_response({ id: 9 }))

      held = ticket
      held.related.customer
      held.assign_attributes(title: 'Renamed', customer_id: 9)

      expect(held.related.customer.id).to eq(9)
    end
  end

  describe '.belongs_to_foreign_keys' do
    it 'lists the keys a resource resolves associations through' do
      expect(ZammadAPI::Resources::Ticket.belongs_to_foreign_keys)
        .to include(:customer_id, :owner_id, :group_id, :state_id, :priority_id, :organization_id)
    end

    it 'includes the ones inherited from Base' do
      expect(ZammadAPI::Resources::Group.belongs_to_foreign_keys).to eq(%i[created_by_id updated_by_id])
    end
  end

  describe '#inspect' do
    it 'names the record and what can be reached from it' do
      expect(ticket.related.inspect)
        .to eq(
          '#<ZammadAPI::Associations::Proxy ZammadAPI::Resources::Ticket id=42 ' \
          'created_by, updated_by, customer, owner, organization, group, state, priority, articles>'
        )
    end
  end
end
