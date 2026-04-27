require 'spec_helper'

describe ZammadAPI, 'ticket priority object basics' do
  client = Helper.client

  name = "some_ticket_priority#{Helper.random}"
  ticket_priority = nil

  it 'new with invalid attributes' do
    ticket_priority_invalid = client.ticket_priority.new

    expect(ticket_priority_invalid.class).to eq(ZammadAPI::Resources::TicketPriority)
    expect(ticket_priority_invalid.new_record?).to be(true)

    expect { ticket_priority_invalid.save }.to raise_error(RuntimeError)
  end

  it 'new with valid attributes' do
    ticket_priority = client.ticket_priority.new(
      name:   name,
      note:   '',
      active: true,
    )

    expect(ticket_priority.class).to eq(ZammadAPI::Resources::TicketPriority)
    expect(ticket_priority.new_record?).to be(true)
    expect(ticket_priority.id).to be_nil
    expect(ticket_priority.name).to eq(name)
    expect(ticket_priority.note).to eq('')
    expect(ticket_priority.active).to be(true)
  end

  it 'save' do
    result = ticket_priority.save

    expect(result).to be(true)
    expect(ticket_priority.id).not_to be_nil
    expect(ticket_priority.name).to eq(name)
    expect(ticket_priority.note).to eq('')
    expect(ticket_priority.active).to be(true)

    ticket_priority.name = "#{name}-2"
    ticket_priority.note = 'some note'
    ticket_priority.active = false

    changes = ticket_priority.changes
    expect(changes.key?(:not_existing)).to be(false)
    expect(changes[:name][0]).to eq(name)
    expect(changes[:name][1]).to eq("#{name}-2")
    expect(changes[:note][0]).to eq('')
    expect(changes[:note][1]).to eq('some note')
    expect(changes[:active][0]).to be(true)
    expect(changes[:active][1]).to be(false)

    result = ticket_priority.save
    expect(result).to be(true)
    expect(ticket_priority.id).to be_present
    expect(ticket_priority.name).to eq("#{name}-2")
    expect(ticket_priority.note).to eq('some note')
    expect(ticket_priority.active).to be(false)
  end

  it 'find' do
    ticket_priority_lookup = client.ticket_priority.find(ticket_priority.id)

    expect(ticket_priority_lookup.class).to eq(ZammadAPI::Resources::TicketPriority)
    expect(ticket_priority_lookup.id).to eq(ticket_priority.id)
    expect(ticket_priority_lookup.name).to eq("#{name}-2")
    expect(ticket_priority_lookup.note).to eq('some note')
    expect(ticket_priority_lookup.active).to be(false)
  end

  it 'all' do
    ticket_priorities = client.ticket_priority.all

    ticket_priority_exists = nil
    ticket_priorities.each do |local_ticket_priority|
      next if local_ticket_priority.id != ticket_priority.id

      ticket_priority_exists = local_ticket_priority
    end
    expect(ticket_priority_exists.class).to eq(ZammadAPI::Resources::TicketPriority)
    expect(ticket_priority_exists.id).to eq(ticket_priority.id)
    expect(ticket_priority_exists.name).to eq("#{name}-2")
    expect(ticket_priority_exists.note).to eq('some note')
    expect(ticket_priority_exists.active).to be(false)

    ticket_priority_exists.active = true
    ticket_priority_exists.save

    ticket_priority_lookup = client.ticket_priority.find(ticket_priority.id)
    expect(ticket_priority_lookup.class).to eq(ZammadAPI::Resources::TicketPriority)
    expect(ticket_priority_lookup.id).to eq(ticket_priority.id)
    expect(ticket_priority_lookup.name).to eq("#{name}-2")
    expect(ticket_priority_lookup.note).to eq('some note')
    expect(ticket_priority_lookup.active).to be(true)
  end

  it 'pagination with all' do
    ticket_priorities = client.ticket_priority.all

    expect(ticket_priorities[0].class).to eq(ZammadAPI::Resources::TicketPriority)

    count = 0
    ticket_priorities.each do |local_ticket_priority|
      expect(local_ticket_priority.class).to eq(ZammadAPI::Resources::TicketPriority)
      count += 1
    end
    expect(count).to eq(4)

    count = 0
    ticket_priorities = client.ticket_priority.all
    ticket_priorities.page(1, 2) do |local_ticket_priority|
      expect(local_ticket_priority.class).to eq(ZammadAPI::Resources::TicketPriority)
      count += 1
    end
    expect(count).to eq(2)
    ticket_priorities.page(2, 2) do |local_ticket_priority|
      expect(local_ticket_priority.class).to eq(ZammadAPI::Resources::TicketPriority)
      count += 1
    end
    expect(count).to eq(4)
    ticket_priorities.page(3, 2) do |local_ticket_priority|
      expect(local_ticket_priority.class).to eq(ZammadAPI::Resources::TicketPriority)
      count += 1
    end
    expect(count).to eq(4)
  end

  it 'destroy' do
    result = ticket_priority.destroy

    expect(result).to be(true)
  end
end
