require 'spec_helper'

describe ZammadAPI, 'organization object basics' do
  client = Helper.client()

  name = "some_organization#{Helper.random()}"
  organization = nil

  it 'new with invalid attributes' do
    organization_invalid = client.organization.new()

    expect(organization_invalid.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization_invalid.new_record?).to eq(true)

    expect { organization_invalid.save }.to raise_error(RuntimeError)
  end

  it 'new with valid attributes' do
    organization = client.organization.new(
      name: name,
      shared: false,
      note: '',
      active: true,
    )

    expect(organization.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization.new_record?).to eq(true)
    expect(organization.id).to eq(nil)
    expect(organization.name).to eq(name)
    expect(organization.shared).to eq(false)
    expect(organization.note).to eq('')
    expect(organization.active).to eq(true)
  end

  it 'save' do
    result = organization.save

    expect(result).to eq(true)
    expect(organization.id).not_to eq(nil)
    expect(organization.name).to eq(name)
    expect(organization.shared).to eq(false)
    expect(organization.note).to eq('')
    expect(organization.active).to eq(true)
    expect(organization.created_by).to eq('admin@example.com')
    expect(organization.updated_by).to eq('admin@example.com')

    organization.name = "#{name}-2"
    organization.note = 'some note'
    organization.shared = true
    organization.active = false

    changes = organization.changes
    expect(changes.key?(:not_existing)).to eq(false)
    expect(changes[:name][0]).to eq(name)
    expect(changes[:name][1]).to eq("#{name}-2")
    expect(changes[:shared][0]).to eq(false)
    expect(changes[:shared][1]).to eq(true)
    expect(changes[:note][0]).to eq('')
    expect(changes[:note][1]).to eq('some note')
    expect(changes[:active][0]).to eq(true)
    expect(changes[:active][1]).to eq(false)

    result = organization.save
    expect(result).to eq(true)
    expect(organization.id).to eq(organization.id)
    expect(organization.name).to eq("#{name}-2")
    expect(organization.shared).to eq(true)
    expect(organization.note).to eq('some note')
    expect(organization.active).to eq(false)
    expect(organization.created_by).to eq('admin@example.com')
    expect(organization.updated_by).to eq('admin@example.com')
  end

  it 'find' do
    organization_lookup = client.organization.find(organization.id)

    expect(organization_lookup.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization_lookup.id).to eq(organization.id)
    expect(organization_lookup.name).to eq("#{name}-2")
    expect(organization_lookup.shared).to eq(true)
    expect(organization_lookup.note).to eq('some note')
    expect(organization_lookup.active).to eq(false)
    expect(organization_lookup.created_by).to eq('admin@example.com')
    expect(organization_lookup.updated_by).to eq('admin@example.com')
  end

  it 'all' do
    organizations = client.organization.all

    organization_exists = nil
    organizations.each { |local_organization|
      next if local_organization.id != organization.id
      organization_exists = local_organization
    }
    expect(organization_exists.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization_exists.id).to eq(organization.id)
    expect(organization_exists.name).to eq("#{name}-2")
    expect(organization_exists.note).to eq('some note')
    expect(organization_exists.active).to eq(false)
    expect(organization_exists.created_by).to eq('admin@example.com')
    expect(organization_exists.updated_by).to eq('admin@example.com')

    organization_exists.active = true
    organization_exists.save

    organization_lookup = client.organization.find(organization.id)
    expect(organization_lookup.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization_lookup.id).to eq(organization.id)
    expect(organization_lookup.name).to eq("#{name}-2")
    expect(organization_lookup.note).to eq('some note')
    expect(organization_lookup.active).to eq(true)
    expect(organization_lookup.created_by).to eq('admin@example.com')
    expect(organization_lookup.updated_by).to eq('admin@example.com')
  end

  it 'pagination with all' do
    organizations = client.organization.all

    expect(organizations[0].class).to eq(ZammadAPI::Resources::Organization)

    count = 0
    organizations.each { |local_organization|
      expect(local_organization.class).to eq(ZammadAPI::Resources::Organization)
      count += 1
    }
    expect(count).to eq(2)

    count = 0
    organizations = client.organization.all
    organizations.page(1, 3) { |local_organization|
      expect(local_organization.class).to eq(ZammadAPI::Resources::Organization)
      count += 1
    }
    expect(count).to eq(2)
    organizations.page(2, 3) { |local_organization|
      expect(local_organization.class).to eq(ZammadAPI::Resources::Organization)
      count += 1
    }
    expect(count).to eq(2)
  end

  it 'search' do
    organizations = client.organization.search(query: name)

    organization_exists = nil
    organizations.each { |local_organization|
      next if local_organization.id != organization.id
      organization_exists = local_organization
    }
    expect(organization_exists.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization_exists.id).to eq(organization.id)
    expect(organization_exists.name).to eq("#{name}-2")
    expect(organization_exists.note).to eq('some note')
    expect(organization_exists.active).to eq(true)
    expect(organization_exists.created_by).to eq('admin@example.com')
    expect(organization_exists.updated_by).to eq('admin@example.com')

    organization_exists.active = false
    organization_exists.save

    organization_lookup = client.organization.find(organization.id)
    expect(organization_lookup.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization_lookup.id).to eq(organization.id)
    expect(organization_lookup.name).to eq("#{name}-2")
    expect(organization_lookup.note).to eq('some note')
    expect(organization_lookup.active).to eq(false)
    expect(organization_lookup.created_by).to eq('admin@example.com')
    expect(organization_lookup.updated_by).to eq('admin@example.com')
  end

  it 'pagination with search' do
    organizations = client.organization.search(query: "#{name}-2")

    expect(organizations[0].class).to eq(ZammadAPI::Resources::Organization)

    count = 0
    organization_exists = nil
    organizations.each { |local_organization|
      expect(local_organization.class).to eq(ZammadAPI::Resources::Organization)
      count += 1
      next if local_organization.id != organization.id
      organization_exists = local_organization
    }
    expect(count).to eq(1)
    expect(organization_exists.class).to eq(ZammadAPI::Resources::Organization)
    expect(organization_exists.id).to eq(organization.id)
    expect(organization_exists.name).to eq("#{name}-2")
    expect(organization_exists.note).to eq('some note')
    expect(organization_exists.active).to eq(false)
    expect(organization_exists.created_by).to eq('admin@example.com')
    expect(organization_exists.updated_by).to eq('admin@example.com')

    count = 0
    organizations = client.organization.search(query: 'zammad')
    organizations.page(1, 3) { |local_organization|
      expect(local_organization.class).to eq(ZammadAPI::Resources::Organization)
      count += 1
    }
    expect(count).to eq(1)
    organizations.page(2, 3) { |local_organization|
      expect(local_organization.class).to eq(ZammadAPI::Resources::Organization)
      count += 1
    }
    expect(count).to eq(1)
  end

  it 'destroy' do
    result = organization.destroy

    expect(result).to eq(true)
  end

end
