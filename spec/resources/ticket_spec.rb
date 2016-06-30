require 'spec_helper'

describe ZammadAPI, 'object basics' do
  client = Helper.client()

  title = "some ticket title ##{Helper.random()}"
  ticket = nil

  it 'new with invalid attributes' do
    ticket_invalid = client.ticket.new()

    expect(ticket_invalid.class).to eq(ZammadAPI::Resources::Ticket)
    expect(ticket_invalid.new_record?).to eq(true)

    expect { ticket_invalid.save }.to raise_error(RuntimeError)
  end

  it 'new with valid attributes' do
    ticket = client.ticket.new(
      title: title,
      state: 'new',
      priority: '2 normal',
      owner: '-',
      customer: 'nicole.braun@zammad.org',
      group: 'Users',
      article: {
        sender: 'Customer',
        type: 'note',
        subject: 'some subject',
        content_type: 'text/plain',
        body: 'some body',
      }
    )

    expect(ticket.class).to eq(ZammadAPI::Resources::Ticket)
    expect(ticket.new_record?).to eq(true)
    expect(ticket.id).to eq(nil)
    expect(ticket.title).to eq(title)
    expect(ticket.state).to eq('new')
    expect(ticket.group).to eq('Users')
    expect(ticket.owner).to eq('-')
  end

  it 'save' do
    result = ticket.save

    expect(result).to eq(true)
    expect(ticket.new_record?).to eq(false)
    expect(ticket.id).not_to eq(nil)
    expect(ticket.title).to eq(title)
    expect(ticket.state).to eq('new')
    expect(ticket.state_id).to eq(1)
    expect(ticket.owner).to eq('-')
    expect(ticket.owner_id).to eq(1)
    expect(ticket.created_by).to eq('master@example.com')
    expect(ticket.updated_by).to eq('master@example.com')

    ticket.title = "#{title}-2"
    ticket.state = 'open'

    changes = ticket.changes
    expect(changes.key?(:state_id)).to eq(false)
    expect(changes.key?(:state)).to eq(true)
    expect(changes[:title][0]).to eq(title)
    expect(changes[:title][1]).to eq("#{title}-2")
    expect(changes[:state][0]).to eq('new')
    expect(changes[:state][1]).to eq('open')

    result = ticket.save
    expect(result).to eq(true)
    expect(ticket.new_record?).to eq(false)
    expect(ticket.id).to eq(ticket.id)
    expect(ticket.title).to eq("#{title}-2")
    expect(ticket.state).to eq('open')
    expect(ticket.state_id).to eq(2)
    expect(ticket.owner).to eq('-')
    expect(ticket.owner_id).to eq(1)
    expect(ticket.created_by).to eq('master@example.com')
    expect(ticket.updated_by).to eq('master@example.com')
  end

  it 'find' do
    ticket_lookup = client.ticket.find(ticket.id)

    expect(ticket_lookup.class).to eq(ZammadAPI::Resources::Ticket)
    expect(ticket_lookup.id).to eq(ticket.id)
    expect(ticket_lookup.title).to eq("#{title}-2")
    expect(ticket_lookup.state).to eq('open')
    expect(ticket_lookup.state_id).to eq(2)
    expect(ticket_lookup.owner).to eq('-')
    expect(ticket_lookup.owner_id).to eq(1)
    expect(ticket_lookup.created_by).to eq('master@example.com')
    expect(ticket_lookup.updated_by).to eq('master@example.com')
  end

  it 'all' do
    tickets = client.ticket.all

    ticket_exists = nil
    tickets.each {|local_ticket|
      next if local_ticket.id != ticket.id
      ticket_exists = local_ticket
    }
    expect(ticket_exists.class).to eq(ZammadAPI::Resources::Ticket)
    expect(ticket_exists.id).to eq(ticket.id)
    expect(ticket_exists.title).to eq("#{title}-2")
    expect(ticket_exists.state).to eq('open')
    expect(ticket_exists.state_id).to eq(2)
    expect(ticket_exists.owner).to eq('-')
    expect(ticket_exists.owner_id).to eq(1)
    expect(ticket_exists.created_by).to eq('master@example.com')
    expect(ticket_exists.updated_by).to eq('master@example.com')

    ticket_exists.state = 'closed'
    ticket_exists.save

    ticket_lookup = client.ticket.find(ticket.id)
    expect(ticket_lookup.class).to eq(ZammadAPI::Resources::Ticket)
    expect(ticket_lookup.id).to eq(ticket.id)
    expect(ticket_lookup.title).to eq("#{title}-2")
    expect(ticket_lookup.state).to eq('closed')
    expect(ticket_lookup.state_id).to eq(4)
    expect(ticket_lookup.owner).to eq('-')
    expect(ticket_lookup.owner_id).to eq(1)
    expect(ticket_lookup.created_by).to eq('master@example.com')
    expect(ticket_lookup.updated_by).to eq('master@example.com')
  end

  it 'pagination with all' do

    (1..10).each {|local_count|
      client.ticket.create(
        title: "test count ticket #{local_count}",
        state: 'new',
        priority: '2 normal',
        owner: '-',
        customer: 'nicole.braun@zammad.org',
        group: 'Users',
        article: {
          sender: 'Customer',
          type: 'note',
          subject: 'some subject',
          content_type: 'text/plain',
          body: 'some body',
        }
      )
    }

    tickets = client.ticket.all
    expect(tickets[0].class).to eq(ZammadAPI::Resources::Ticket)
    count = 0
    tickets.each {|local_ticket|
      expect(local_ticket.class).to eq(ZammadAPI::Resources::Ticket)
      count += 1
    }
    expect(count).to eq(13)

    count = 0
    tickets = client.ticket.all
    tickets.page(1, 5) {|local_ticket|
      expect(local_ticket.class).to eq(ZammadAPI::Resources::Ticket)
      count += 1
    }
    expect(count).to eq(5)
    tickets.page(2, 5) {|local_ticket|
      expect(local_ticket.class).to eq(ZammadAPI::Resources::Ticket)
      count += 1
    }
    expect(count).to eq(10)
    tickets.page(3, 5) {|local_ticket|
      expect(local_ticket.class).to eq(ZammadAPI::Resources::Ticket)
      count += 1
    }
    expect(count).to eq(13)
  end

  it 'destroy' do
    result = ticket.destroy

    expect(result).to eq(true)
  end

end
