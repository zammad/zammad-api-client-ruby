#!/usr/bin/env ruby
# frozen_string_literal: true

# Onboards a new customer: organization, user, and a welcome ticket raised as
# that user.
#
# Shows `find_by` for a lookup by attribute, `create`, and `on_behalf_of` both
# as a scoped client and as a block.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     bundle exec ruby examples/onboard_customer.rb "Acme Inc" jane@acme.test Jane Doe

require 'zammad_api'

client = ZammadAPI::Client.from_env

company, email, firstname, lastname = ARGV
abort "usage: #{$PROGRAM_NAME} COMPANY EMAIL FIRSTNAME LASTNAME" if [company, email, firstname, lastname].any?(&:nil?)

# Zammad stores an address trimmed and in lower case, and `find_by` matches a
# value exactly. Looked up as typed, Jane@Acme.Test misses the jane@acme.test
# Zammad holds: the check below then sees no user, and the script makes the
# organization before Zammad refuses the address as taken.
email = email.strip.downcase

# `find_by` searches and then checks the hits itself, because Zammad's index
# endpoints cannot filter. It returns a record that genuinely carries the
# attribute, or nil - never an unrelated one.
#
# What the search surfaces is Zammad's business, so a value it has not indexed
# is a record this will not find, and the `||= create` below would then make a
# second organization. Searching by hand has the same gap.
organization = client.organizations.find_by(name: company)
user         = client.users.find_by(email: email)

# An address Zammad already knows is only this customer's if it sits in this
# organization. Reused regardless, a jane@acme.test who belongs to Contoso
# got Acme's welcome ticket and a report that all was well, with nothing
# having put that user in Acme. Moving a user is not this script's call
# either, so it stops, before anything is created. `[]` rather than a reader,
# because a user with no organization may not carry the attribute at all.
if user && (organization.nil? || user[:organization_id] != organization.id)
  # Named where the response carries the name, by id where it carries only
  # that, and "no organization" only for a user that has neither.
  current = user[:organization] || (user[:organization_id] ? "organization id=#{user[:organization_id]}" : 'no organization')

  abort "#{email} is already a user (id=#{user.id}) of #{current}, not of #{company}. " \
        'Nothing was created or changed. Move the user in Zammad first, if that is what is meant.'
end

organization ||= client.organizations.create(name: company)

puts "organization: #{organization.name} (id=#{organization.id})"

user ||= client.users.create(
  firstname:       firstname,
  lastname:        lastname,
  email:           email,
  organization_id: organization.id,
  roles:           ['Customer']
)

puts "user:         #{user.firstname} #{user.lastname} <#{user.email}> (id=#{user.id})"

# `on_behalf_of` returns a new client rather than mutating this one, so the
# admin client stays unscoped and both remain safe to use.
as_customer = client.on_behalf_of(user.email)

ticket = as_customer.tickets.create(
  title:    "Welcome, #{firstname}!",
  group:    'Users',
  customer: user.email,
  article:  {
    subject: 'Getting started',
    body:    "Hi #{firstname},\n\nyour account is ready.",
    type:    'note'
  }
)

puts "ticket:       ##{ticket.number} raised as #{user.email}"

# The block form scopes a single operation.
own_tickets = client.on_behalf_of(user.email) { |scoped| scoped.tickets.all.count }

puts "the customer can see #{own_tickets} ticket(s) of their own"
