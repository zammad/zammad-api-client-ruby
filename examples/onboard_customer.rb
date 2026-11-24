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

abort "usage: #{$PROGRAM_NAME} COMPANY EMAIL FIRSTNAME LASTNAME" if ARGV.size < 4

company, email, firstname, lastname = ARGV
email = email.downcase # Zammad stores addresses in lower case, and find_by matches exactly

client = ZammadAPI::Client.from_env

# `find_by` returns the first record carrying exactly these values, or nil.
organization = client.organizations.find_by(name: company) || client.organizations.create(name: company)

puts "organization: #{organization.name} (id=#{organization.id})"

user = client.users.find_by(email: email) || client.users.create(
  firstname:       firstname,
  lastname:        lastname,
  email:           email,
  organization_id: organization.id,
  roles:           ['Customer']
)

puts "user:         #{user.firstname} #{user.lastname} <#{user.email}> (id=#{user.id})"

# `on_behalf_of` returns a new client rather than changing this one, so the
# admin client stays unscoped.
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
