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

    # The one list in the gem read in a single request, because the endpoint
    # it is declared against serves the whole thing: index_by_ticket iterates
    # `ticket.articles` and renders them all, with no pagination to opt into.
    # A guard used to sit here for a target that paged anyway, reading a total
    # from a response header - a header Zammad sends from no endpoint, so it
    # never once looked at a figure.
    it 'reads the whole list in one request' do
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

  # `related = ticket.related` is the natural thing to write before reading
  # two associations. The record used to drop its proxy and build another, so
  # everything under 'the memo' above held for a caller who asked the record
  # again and for nobody who had kept what they were handed.
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

    it 'keeps its memo across a write no association resolves through' do
      related.customer
      ticket.title = 'Renamed'
      related.customer

      expect(a_request(:get, "#{users_url}/7").with(query: hash_including({}))).to have_been_made.once
    end

    context 'when the record was destroyed' do
      before do
        stub_request(:delete, ticket_url).to_return(json_response({}))
        related.customer
        ticket.destroy
      end

      it 'refuses a target it had already resolved' do
        expect { related.customer }
          .to raise_error(ZammadAPI::Error, 'ZammadAPI::Resources::Ticket 42 was destroyed, there is nothing to read customer from')
      end

      it 'refuses a list, rather than requesting it for a record that is gone' do
        expect { related.articles }.to raise_error(ZammadAPI::Error, /was destroyed/)
        expect(a_request(:get, %r{ticket_articles/by_ticket})).not_to have_been_made
      end
    end

    # The write clears the memo, and the lookup that was already out then
    # filled it again, with the record behind the value from before. A logger
    # or a middleware of the caller's that reaches the record is enough, on
    # one thread; so is a second thread.
    context 'when the foreign key is written while a lookup is on the wire' do
      before do
        stub_request(:get, "#{users_url}/7").with(query: hash_including({})).to_return do
          ticket.customer_id = 9
          json_response({ id: 7 })
        end
      end

      it 'answers that lookup with the record it asked for' do
        expect(related.customer.id).to eq(7)
      end

      it 'does not keep that answer for the record the key now names' do
        related.customer

        expect(related.customer.id).to eq(9)
      end

      it 'memoizes the lookup made after it' do
        3.times { related.customer }

        expect(a_request(:get, "#{users_url}/9").with(query: hash_including({}))).to have_been_made.once
      end
    end

    it 'leaves the proxy of a copy to the copy' do
      related.customer
      copy = ticket.dup
      copy.customer_id = 9

      expect(related.customer.id).to eq(7)
      expect(copy.related.customer.id).to eq(9)
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

    # The list is built at the first write to an attribute and kept. An
    # association declared after that was never in it, so a write to its
    # foreign key left the record it had resolved in place.
    context 'when an association is declared after the list was built' do
      let(:resource) { Class.new(ZammadAPI::Resources::Base) { path 'api/v1/memberships' } }

      before { stub_const('Acme::Role', Class.new(ZammadAPI::Resources::Base) { path 'api/v1/roles' }) }

      def declare_role = resource.send(:belongs_to, :role, class_name: 'Acme::Role')

      it 'takes in its foreign key' do
        resource.belongs_to_foreign_keys
        declare_role

        expect(resource.belongs_to_foreign_keys).to eq(%i[created_by_id updated_by_id role_id])
      end

      it 'takes it in on a class that inherits the declaration' do
        subclass = Class.new(resource)
        subclass.belongs_to_foreign_keys
        declare_role

        expect(subclass.belongs_to_foreign_keys).to include(:role_id)
      end

      it 'drops what the association resolved when its foreign key is written' do
        [5, 6].each do |id|
          stub_request(:get, "#{ClientHelper::BASE_URL}api/v1/roles/#{id}").with(query: hash_including({})).to_return(json_response({ id: id }))
        end
        record = resource.from_response(unit_transport, id: 1, role_id: 5)
        record.note = 'written before the declaration'
        declare_role
        record.related.role
        record.role_id = 6

        expect(record.related.role.id).to eq(6)
      end
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
