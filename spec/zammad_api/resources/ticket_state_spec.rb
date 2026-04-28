require 'spec_helper'

describe ZammadAPI, 'ticket state object basics' do
  let(:client) { Helper.client }

  let(:name) { "some_ticket_state#{Helper.random}" }
  let(:ticket_state) { nil }

  it 'new with invalid attributes' do
    ticket_state_invalid = client.ticket_state.new

    expect(ticket_state_invalid.class).to eq(ZammadAPI::Resources::TicketState)
    expect(ticket_state_invalid.new_record?).to be(true)

    expect { ticket_state_invalid.save }.to raise_error(RuntimeError)
  end

  it 'new with valid attributes' do
    ticket_state = client.ticket_state.new(
      name:              name,
      state_type:        'new',
      next_state_id:     nil,
      ignore_escalation: false,
      note:              '',
      active:            true,
    )

    expect(ticket_state.class).to eq(ZammadAPI::Resources::TicketState)
    expect(ticket_state.new_record?).to be(true)
    expect(ticket_state.id).to be_nil
    expect(ticket_state.name).to eq(name)
    expect(ticket_state.state_type).to eq('new')
    expect(ticket_state.state_type_id).to be_nil
    expect(ticket_state.next_state_id).to be_nil
    expect(ticket_state.ignore_escalation).to be(false)
    expect(ticket_state.note).to eq('')
    expect(ticket_state.active).to be(true)
  end

  it 'save' do
    result = ticket_state.save

    expect(result).to be(true)
    expect(ticket_state.id).not_to be_nil
    expect(ticket_state.name).to eq(name)
    expect(ticket_state.state_type).to eq('new')
    expect(ticket_state.state_type_id).to eq(1)
    expect(ticket_state.next_state_id).to be_nil
    expect(ticket_state.ignore_escalation).to be(false)
    expect(ticket_state.note).to eq('')
    expect(ticket_state.active).to be(true)
    expect(ticket_state.created_by).to eq('admin@example.com')
    expect(ticket_state.updated_by).to eq('admin@example.com')

    ticket_state.name = "#{name}-2"
    ticket_state.note = 'some note'
    ticket_state.state_type = 'open'
    ticket_state.next_state = 'closed'
    ticket_state.ignore_escalation = true
    ticket_state.active = false

    changes = ticket_state.changes
    expect(changes.key?(:next_state_id)).to be(false)
    expect(changes.key?(:next_state)).to be(true)
    expect(changes[:name][0]).to eq(name)
    expect(changes[:name][1]).to eq("#{name}-2")
    expect(changes[:state_type][0]).to eq('new')
    expect(changes[:state_type][1]).to eq('open')
    expect(changes[:next_state][0]).to be_nil
    expect(changes[:next_state][1]).to eq('closed')
    expect(changes[:ignore_escalation][0]).to be(false)
    expect(changes[:ignore_escalation][1]).to be(true)
    expect(changes[:note][0]).to eq('')
    expect(changes[:note][1]).to eq('some note')
    expect(changes[:active][0]).to be(true)
    expect(changes[:active][1]).to be(false)

    result = ticket_state.save
    expect(result).to be(true)
    expect(ticket_state.id).to be_a(Integer)
    expect(ticket_state.name).to eq("#{name}-2")
    expect(ticket_state.state_type).to eq('open')
    expect(ticket_state.state_type_id).to eq(2)
    expect(ticket_state.next_state).to eq('closed')
    expect(ticket_state.next_state_id).to eq(4)
    expect(ticket_state.ignore_escalation).to be(true)
    expect(ticket_state.note).to eq('some note')
    expect(ticket_state.active).to be(false)
    expect(ticket_state.created_by).to eq('admin@example.com')
    expect(ticket_state.updated_by).to eq('admin@example.com')
  end

  it 'find' do
    ticket_state_lookup = client.ticket_state.find(ticket_state.id)

    expect(ticket_state_lookup.class).to eq(ZammadAPI::Resources::TicketState)
    expect(ticket_state_lookup.id).to eq(ticket_state.id)
    expect(ticket_state_lookup.name).to eq("#{name}-2")
    expect(ticket_state_lookup.state_type).to eq('open')
    expect(ticket_state_lookup.state_type_id).to eq(2)
    expect(ticket_state_lookup.next_state).to eq('closed')
    expect(ticket_state_lookup.next_state_id).to eq(4)
    expect(ticket_state_lookup.ignore_escalation).to be(true)
    expect(ticket_state_lookup.note).to eq('some note')
    expect(ticket_state_lookup.active).to be(false)
    expect(ticket_state_lookup.created_by).to eq('admin@example.com')
    expect(ticket_state_lookup.updated_by).to eq('admin@example.com')
  end

  it 'all' do
    ticket_states = client.ticket_state.all

    ticket_state_exists = nil
    ticket_states.each do |local_ticket_state|
      next if local_ticket_state.id != ticket_state.id

      ticket_state_exists = local_ticket_state
    end
    expect(ticket_state_exists.class).to eq(ZammadAPI::Resources::TicketState)
    expect(ticket_state_exists.id).to eq(ticket_state.id)
    expect(ticket_state_exists.name).to eq("#{name}-2")
    expect(ticket_state_exists.state_type).to eq('open')
    expect(ticket_state_exists.state_type_id).to eq(2)
    expect(ticket_state_exists.next_state).to eq('closed')
    expect(ticket_state_exists.next_state_id).to eq(4)
    expect(ticket_state_exists.ignore_escalation).to be(true)
    expect(ticket_state_exists.note).to eq('some note')
    expect(ticket_state_exists.active).to be(false)
    expect(ticket_state_exists.created_by).to eq('admin@example.com')
    expect(ticket_state_exists.updated_by).to eq('admin@example.com')

    ticket_state_exists.active = true
    ticket_state_exists.save

    ticket_state_lookup = client.ticket_state.find(ticket_state.id)
    expect(ticket_state_lookup.class).to eq(ZammadAPI::Resources::TicketState)
    expect(ticket_state_lookup.id).to eq(ticket_state.id)
    expect(ticket_state_lookup.name).to eq("#{name}-2")
    expect(ticket_state_lookup.state_type).to eq('open')
    expect(ticket_state_lookup.state_type_id).to eq(2)
    expect(ticket_state_lookup.next_state).to eq('closed')
    expect(ticket_state_lookup.next_state_id).to eq(4)
    expect(ticket_state_lookup.note).to eq('some note')
    expect(ticket_state_lookup.active).to be(true)
    expect(ticket_state_lookup.created_by).to eq('admin@example.com')
    expect(ticket_state_lookup.updated_by).to eq('admin@example.com')
  end

  it 'pagination with all' do
    ticket_states = client.ticket_state.all

    expect(ticket_states[0].class).to eq(ZammadAPI::Resources::TicketState)

    count = 0
    ticket_states.each do |local_ticket_state|
      expect(local_ticket_state.class).to eq(ZammadAPI::Resources::TicketState)
      count += 1
    end
    expect(count).to be >= 7

    count = 0
    ticket_states = client.ticket_state.all
    ticket_states.page(1, 3) do |local_ticket_state|
      expect(local_ticket_state.class).to eq(ZammadAPI::Resources::TicketState)
      count += 1
    end
    expect(count).to eq(3)
    ticket_states.page(2, 3) do |local_ticket_state|
      expect(local_ticket_state.class).to eq(ZammadAPI::Resources::TicketState)
      count += 1
    end
    expect(count).to eq(6)
    ticket_states.page(3, 3) do |local_ticket_state|
      expect(local_ticket_state.class).to eq(ZammadAPI::Resources::TicketState)
      count += 1
    end
    expect(count).to be >= 7
  end

  it 'destroy' do
    result = ticket_state.destroy

    expect(result).to be(true)
  end
end
