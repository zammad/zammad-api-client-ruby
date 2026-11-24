# frozen_string_literal: true

RSpec.describe ZammadAPI::Associations::Proxy do
  subject(:ticket) { client.tickets.find(42) }

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

    it 'is dropped by a write to any attribute' do
      held = ticket
      held.related.customer
      held.title = 'Renamed'
      held.related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.twice
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

  describe 'a proxy the caller kept' do
    let(:related) { ticket.related }

    before do
      stub_request(:get, "#{users_url}/7").with(query: hash_including({})).to_return(json_response({ id: 7 }))
      stub_request(:get, "#{users_url}/9").with(query: hash_including({})).to_return(json_response({ id: 9 }))
    end

    it 'is the one the record goes on handing out' do
      related.customer
      ticket.customer_id = 9

      expect(ticket.related).to be(related)
    end

    it 'follows a foreign key that was written' do
      expect(related.customer.id).to eq(7)

      ticket.customer_id = 9

      expect(related.customer.id).to eq(9)
    end

    it 'follows a foreign key that assign_attributes wrote' do
      related.customer
      ticket.assign_attributes(title: 'Renamed', customer_id: 9)

      expect(related.customer.id).to eq(9)
    end

    it 'follows a foreign key that a reload moved' do
      related.customer
      stub_request(:get, ticket_url).with(query: hash_including({})).to_return(json_response(ticket_attributes.merge(customer_id: 9)))
      ticket.reload

      expect(related.customer.id).to eq(9)
    end

    it 'fetches the target again after a reload that left the foreign key alone' do
      related.customer
      ticket.reload
      related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.twice
    end

    it 'fetches the target again after a save' do
      stub_request(:put, ticket_url).with(query: hash_including({})).to_return(json_response(ticket_attributes))

      related.customer
      ticket.update!(title: 'Renamed')
      related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.twice
    end

    it 'fetches the target again after a write to any attribute' do
      related.customer
      ticket.title = 'Renamed'
      related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.twice
    end

    it 'leaves the proxy of a copy to the copy' do
      related.customer
      copy = ticket.dup
      copy.customer_id = 9

      expect(related.customer.id).to eq(7)
      expect(copy.related.customer.id).to eq(9)
    end
  end

  describe '#inspect' do
    it 'names the record and what can be reached from it' do
      expect(ticket.related.inspect)
        .to eq(
          '#<ZammadAPI::Associations::Proxy ZammadAPI::Resources::Ticket id=42 ' \
          'created_by, updated_by, customer, owner, organization, group, state, priority>'
        )
    end
  end

  # A resource a caller declares can point at another of theirs, which is in
  # no namespace of this gem.
  describe 'an association declared on a resource a caller wrote' do
    before do
      stub_const('Acme::Role', Class.new(ZammadAPI::Resources::Base) { path 'api/v1/roles' })
      stub_const('Acme::Membership', Class.new(ZammadAPI::Resources::Base) do
        path 'api/v1/memberships'
        belongs_to :role, class_name: 'Acme::Role'
        belongs_to :user, class_name: 'User'
      end)
    end

    let(:membership) { Acme::Membership.from_response(unit_transport, id: 1, role_id: 2, user_id: 3) }

    it 'resolves a target named by its full name' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/roles/2").with(query: hash_including({}))
        .to_return(json_response({ id: 2, name: 'Agent' }))

      expect(membership.related.role).to be_a(Acme::Role)
    end

    it 'still resolves a resource of this gem by its own name' do
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/3").with(query: hash_including({}))
        .to_return(json_response({ id: 3, login: 'agent' }))

      expect(membership.related.user).to be_a(ZammadAPI::Resources::User)
    end

    # An application is likely to have a User of its own at the top level.
    it 'prefers the resource of this gem over a top-level constant of the same name' do
      stub_const('User', Class.new)
      stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/users/3").with(query: hash_including({}))
        .to_return(json_response({ id: 3, login: 'agent' }))

      expect(membership.related.user).to be_a(ZammadAPI::Resources::User)
    end
  end
end
