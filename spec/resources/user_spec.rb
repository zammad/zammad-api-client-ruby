require 'spec_helper'

describe ZammadAPI, 'user object basics' do
  client = Helper.client()

  random = Helper.random()
  firstname = "firstname#{random}"
  lastname = "lastname#{random}"
  email = "some_user#{random}@example.com"
  user = nil

  it 'new with invalid attributes' do
    user_invalid = client.user.new()

    expect(user_invalid.class).to eq(ZammadAPI::Resources::User)
    expect(user_invalid.new_record?).to eq(true)

    expect { user_invalid.save }.to raise_error(RuntimeError)
  end

  it 'new with valid attributes' do
    user = client.user.new(
      firstname: firstname,
      lastname: lastname,
      email: email,
      #group_ids: [1],
      #role_ids: [3],
      groups: ['Users'],
      roles: ['Customer'],
      preferences: { key1: 123, key2: 'abc' },
      note: '',
      active: true,
    )

    expect(user.class).to eq(ZammadAPI::Resources::User)
    expect(user.new_record?).to eq(true)
    expect(user.id).to eq(nil)
    expect(user.firstname).to eq(firstname)
    expect(user.lastname).to eq(lastname)
    expect(user.email).to eq(email)
    expect(user.preferences).to eq({ key1: 123, key2: 'abc' })
    expect(user.note).to eq('')
    expect(user.active).to eq(true)
  end

  it 'save' do
    result = user.save

    expect(result).to eq(true)
    expect(user.id).not_to eq(nil)
    expect(user.firstname).to eq(firstname)
    expect(user.lastname).to eq(lastname)
    expect(user.email).to eq(email)
    expect(user.group_ids).to eq([1])
    expect(user.groups).to eq(['Users'])
    expect(user.role_ids).to eq([3])
    expect(user.roles).to eq(['Customer'])
    expect(user.preferences).to eq({ key1: 123, key2: 'abc' })
    expect(user.note).to eq('')
    expect(user.active).to eq(true)
    expect(user.created_by).to eq('master@example.com')
    expect(user.updated_by).to eq('master@example.com')

    user.firstname = "firstname#{random}-2"
    user.roles = ['Agent']
    user.note = 'some note'
    user.active = false

    changes = user.changes
    expect(changes.key?(:lastname)).to eq(false)
    expect(changes[:firstname][0]).to eq(firstname)
    expect(changes[:firstname][1]).to eq("#{firstname}-2")
    expect(changes[:note][0]).to eq('')
    expect(changes[:note][1]).to eq('some note')
    expect(changes[:active][0]).to eq(true)
    expect(changes[:active][1]).to eq(false)

    result = user.save
    expect(result).to eq(true)
    expect(user.id).to eq(user.id)
    expect(user.firstname).to eq("#{firstname}-2")
    expect(user.lastname).to eq(lastname)
    expect(user.email).to eq(email)
    expect(user.group_ids).to eq([1])
    expect(user.groups).to eq(['Users'])
    expect(user.role_ids).to eq([2])
    expect(user.roles).to eq(['Agent'])
    expect(user.note).to eq('some note')
    expect(user.active).to eq(false)
    expect(user.created_by).to eq('master@example.com')
    expect(user.updated_by).to eq('master@example.com')
  end

  it 'find' do
    user_lookup = client.user.find(user.id)

    expect(user_lookup.class).to eq(ZammadAPI::Resources::User)
    expect(user_lookup.id).to eq(user.id)
    expect(user_lookup.firstname).to eq("#{firstname}-2")
    expect(user_lookup.lastname).to eq(lastname)
    expect(user_lookup.email).to eq(email)
    expect(user_lookup.group_ids).to eq([1])
    expect(user_lookup.groups).to eq(['Users'])
    expect(user_lookup.role_ids).to eq([2])
    expect(user_lookup.roles).to eq(['Agent'])
    expect(user_lookup.note).to eq('some note')
    expect(user_lookup.active).to eq(false)
    expect(user_lookup.created_by).to eq('master@example.com')
    expect(user_lookup.updated_by).to eq('master@example.com')

  end

  it 'all' do
    users = client.user.all

    user_exists = nil
    users.each { |local_user|
      next if local_user.id != user.id
      user_exists = local_user
    }
    expect(user_exists.class).to eq(ZammadAPI::Resources::User)
    expect(user_exists.id).to eq(user.id)
    expect(user_exists.id).to eq(user.id)
    expect(user_exists.firstname).to eq("#{firstname}-2")
    expect(user_exists.lastname).to eq(lastname)
    expect(user_exists.email).to eq(email)
    expect(user_exists.group_ids).to eq([1])
    expect(user_exists.groups).to eq(['Users'])
    expect(user_exists.role_ids).to eq([2])
    expect(user_exists.roles).to eq(['Agent'])
    expect(user_exists.note).to eq('some note')
    expect(user_exists.active).to eq(false)
    expect(user_exists.created_by).to eq('master@example.com')
    expect(user_exists.updated_by).to eq('master@example.com')

    user_exists.active = true
    user_exists.save

    user_lookup = client.user.find(user.id)
    expect(user_lookup.class).to eq(ZammadAPI::Resources::User)
    expect(user_lookup.id).to eq(user.id)
    expect(user_lookup.firstname).to eq("#{firstname}-2")
    expect(user_lookup.lastname).to eq(lastname)
    expect(user_lookup.email).to eq(email)
    expect(user_lookup.group_ids).to eq([1])
    expect(user_lookup.groups).to eq(['Users'])
    expect(user_lookup.role_ids).to eq([2])
    expect(user_lookup.roles).to eq(['Agent'])
    expect(user_lookup.note).to eq('some note')
    expect(user_lookup.active).to eq(true)
    expect(user_lookup.created_by).to eq('master@example.com')
    expect(user_lookup.updated_by).to eq('master@example.com')

  end

  it 'pagination with all' do
    (1..10).each { |local_count|
      client.user.create(
        firstname: "firstname#{local_count}",
        lastname: "lastname#{local_count}",
        email: "customer_email#{local_count}@example.com",
        groups: ['Users'],
        roles: ['Customer'],
        note: '',
        active: true,
      )
    }

    users = client.user.all

    expect(users[0].class).to eq(ZammadAPI::Resources::User)
    count = 0
    users.each { |local_user|
      expect(local_user.class).to eq(ZammadAPI::Resources::User)
      count += 1
    }
    expect(count).to eq(15)

    count = 0
    users = client.user.all
    users.page(1, 4) { |local_user|
      expect(local_user.class).to eq(ZammadAPI::Resources::User)
      count += 1
    }
    expect(count).to eq(4)
    users.page(2, 5) { |local_user|
      expect(local_user.class).to eq(ZammadAPI::Resources::User)
      count += 1
    }
    expect(count).to eq(9)
    count = 0
    users.page(1, 200) { |local_user|
      expect(local_user.class).to eq(ZammadAPI::Resources::User)
      count += 1
    }
    expect(count).to eq(15)
  end

  it 'search' do
    users = client.user.search(term: firstname)

    user_exists = nil
    users.each { |local_user|
      next if local_user.id != user.id
      user_exists = local_user
    }
    expect(user_exists.class).to eq(ZammadAPI::Resources::User)
    expect(user_exists.id).to eq(user.id)
    expect(user_exists.firstname).to eq("#{firstname}-2")
    expect(user_exists.group_ids).to eq([1])
    expect(user_exists.groups).to eq(['Users'])
    expect(user_exists.role_ids).to eq([2])
    expect(user_exists.roles).to eq(['Agent'])
    expect(user_exists.active).to eq(true)
    expect(user_exists.created_by).to eq('master@example.com')
    expect(user_exists.updated_by).to eq('master@example.com')

    user_exists.active = false
    user_exists.save

    user_lookup = client.user.find(user.id)
    expect(user_lookup.class).to eq(ZammadAPI::Resources::User)
    expect(user_lookup.id).to eq(user.id)
    expect(user_lookup.firstname).to eq("#{firstname}-2")
    expect(user_lookup.group_ids).to eq([1])
    expect(user_lookup.groups).to eq(['Users'])
    expect(user_lookup.role_ids).to eq([2])
    expect(user_lookup.roles).to eq(['Agent'])
    expect(user_lookup.active).to eq(false)
    expect(user_lookup.created_by).to eq('master@example.com')
    expect(user_lookup.updated_by).to eq('master@example.com')

  end

  it 'pagination with search' do
    users = client.user.search(term: firstname)

    expect(users[0].class).to eq(ZammadAPI::Resources::User)

    count = 0
    user_exists = nil
    users.each { |local_user|
      expect(local_user.class).to eq(ZammadAPI::Resources::User)
      count += 1
      next if local_user.id != user.id
      user_exists = local_user
    }
    expect(count).to eq(1)
    expect(user_exists.class).to eq(ZammadAPI::Resources::User)
    expect(user_exists.id).to eq(user.id)
    expect(user_exists.firstname).to eq("#{firstname}-2")
    expect(user_exists.group_ids).to eq([1])
    expect(user_exists.groups).to eq(['Users'])
    expect(user_exists.role_ids).to eq([2])
    expect(user_exists.roles).to eq(['Agent'])
    expect(user_exists.active).to eq(false)
    expect(user_exists.created_by).to eq('master@example.com')
    expect(user_exists.updated_by).to eq('master@example.com')

    count = 0
    users = client.user.search(term: firstname)
    users.page(1, 3) { |local_user|
      expect(local_user.class).to eq(ZammadAPI::Resources::User)
      count += 1
    }
    expect(count).to eq(1)
    users.page(2, 3) { |local_user|
      expect(local_user.class).to eq(ZammadAPI::Resources::User)
      count += 1
    }
    expect(count).to eq(1)
  end

  it 'destroy' do

    # wait until zammad scheduler wrote some entries to activiy stream
    # to have some references and not allow users to delete
    sleep 12

    expect { user.destroy }.to raise_error(RuntimeError)
    #result = user.destroy
    #expect(result).to eq(true)
  end

end
