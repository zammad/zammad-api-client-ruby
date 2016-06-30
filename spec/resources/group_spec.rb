require 'spec_helper'

describe ZammadAPI, 'object basics' do
  client = Helper.client()

  name = "some_group#{Helper.random()}"
  group = nil

  it 'new with invalid attributes' do
    group_invalid = client.group.new()

    expect(group_invalid.class).to eq(ZammadAPI::Resources::Group)
    expect(group_invalid.new_record?).to eq(true)

    expect { group_invalid.save }.to raise_error(RuntimeError)
  end

  it 'new with valid attributes' do
    group = client.group.new(
      name: name,
      assignment_timeout: 100,
      follow_up_assignment: false,
      follow_up_possible: 'reject',
      note: '',
      active: true,
    )

    expect(group.class).to eq(ZammadAPI::Resources::Group)
    expect(group.new_record?).to eq(true)
    expect(group.id).to eq(nil)
    expect(group.name).to eq(name)
    expect(group.assignment_timeout).to eq(100)
    expect(group.follow_up_assignment).to eq(false)
    expect(group.follow_up_possible).to eq('reject')
    expect(group.note).to eq('')
    expect(group.active).to eq(true)
  end

  it 'save' do
    result = group.save

    expect(result).to eq(true)
    expect(group.id).not_to eq(nil)
    expect(group.name).to eq(name)
    expect(group.assignment_timeout).to eq(100)
    expect(group.follow_up_assignment).to eq(false)
    expect(group.follow_up_possible).to eq('reject')
    expect(group.note).to eq('')
    expect(group.active).to eq(true)

    group.name = "#{name}-2"
    group.note = 'some note'
    group.assignment_timeout = 4711
    group.active = false

    changes = group.changes
    expect(changes.key?(:follow_up_possible)).to eq(false)
    expect(changes[:name][0]).to eq(name)
    expect(changes[:name][1]).to eq("#{name}-2")
    expect(changes[:assignment_timeout][0]).to eq(100)
    expect(changes[:assignment_timeout][1]).to eq(4711)
    expect(changes[:note][0]).to eq('')
    expect(changes[:note][1]).to eq('some note')
    expect(changes[:active][0]).to eq(true)
    expect(changes[:active][1]).to eq(false)

    result = group.save
    expect(result).to eq(true)
    expect(group.id).to eq(group.id)
    expect(group.name).to eq("#{name}-2")
    expect(group.assignment_timeout).to eq(4711)
    expect(group.follow_up_assignment).to eq(false)
    expect(group.follow_up_possible).to eq('reject')
    expect(group.note).to eq('some note')
    expect(group.active).to eq(false)

  end

  it 'find' do
    group_lookup = client.group.find(group.id)

    expect(group_lookup.class).to eq(ZammadAPI::Resources::Group)
    expect(group_lookup.id).to eq(group.id)
    expect(group_lookup.name).to eq("#{name}-2")
    expect(group_lookup.assignment_timeout).to eq(4711)
    expect(group_lookup.follow_up_assignment).to eq(false)
    expect(group_lookup.follow_up_possible).to eq('reject')
    expect(group_lookup.note).to eq('some note')
    expect(group_lookup.active).to eq(false)
  end

  it 'all' do
    groups = client.group.all

    group_exists = nil
    groups.each {|local_group|
      next if local_group.id != group.id
      group_exists = local_group
    }
    expect(group_exists.class).to eq(ZammadAPI::Resources::Group)
    expect(group_exists.id).to eq(group.id)
    expect(group_exists.name).to eq("#{name}-2")
    expect(group_exists.assignment_timeout).to eq(4711)
    expect(group_exists.follow_up_assignment).to eq(false)
    expect(group_exists.follow_up_possible).to eq('reject')
    expect(group_exists.note).to eq('some note')
    expect(group_exists.active).to eq(false)

    group_exists.active = true
    group_exists.save

    group_lookup = client.group.find(group.id)
    expect(group_lookup.class).to eq(ZammadAPI::Resources::Group)
    expect(group_lookup.id).to eq(group.id)
    expect(group_lookup.name).to eq("#{name}-2")
    expect(group_lookup.assignment_timeout).to eq(4711)
    expect(group_lookup.follow_up_assignment).to eq(false)
    expect(group_lookup.follow_up_possible).to eq('reject')
    expect(group_lookup.note).to eq('some note')
    expect(group_lookup.active).to eq(true)
  end

  it 'pagination with all' do
    groups = client.group.all

    expect(groups[0].class).to eq(ZammadAPI::Resources::Group)

    count = 0
    groups.each {|local_group|
      expect(local_group.class).to eq(ZammadAPI::Resources::Group)
      count += 1
    }
    expect(count).to eq(3)

    count = 0
    groups = client.group.all
    groups.page(1, 3) {|local_group|
      expect(local_group.class).to eq(ZammadAPI::Resources::Group)
      count += 1
    }
    expect(count).to eq(3)
    groups.page(2, 3) {|local_group|
      expect(local_group.class).to eq(ZammadAPI::Resources::Group)
      count += 1
    }
    expect(count).to eq(3)
  end

  it 'destroy' do
    result = group.destroy

    expect(result).to eq(true)
  end

end
