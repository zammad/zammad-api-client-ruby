#!/usr/bin/env ruby
# frozen_string_literal: true

# Onboards a new customer: organization, user, and a welcome ticket raised
# as that user.
#
# Demonstrates: create, `on_behalf_of` returning a scoped client, and the
# block form for a single scoped operation.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/onboard_customer.rb "Acme Inc" jane@acme.test Jane Doe

require 'zammad_api'

client = ZammadAPI::Client.new(
  url:        ENV.fetch('ZAMMAD_URL'),
  http_token: ENV.fetch('ZAMMAD_TOKEN')
)

company, email, firstname, lastname = ARGV
abort "usage: #{$PROGRAM_NAME} COMPANY EMAIL FIRSTNAME LASTNAME" if [company, email, firstname, lastname].any?(&:nil?)

# Reuse the organization if it already exists.
organization = client.organization.search(query: company).find { it.name == company } ||
               client.organization.create(name: company, note: 'Created by onboard_customer.rb')

puts "organization: #{organization.name} (id=#{organization.id})"

user = client.user.search(query: email).find { it.email == email } ||
       client.user.create(
         firstname:       firstname,
         lastname:        lastname,
         email:           email,
         organization_id: organization.id,
         roles:           ['Customer']
       )

puts "user:         #{user.firstname} #{user.lastname} <#{user.email}> (id=#{user.id})"

# `on_behalf_of` returns a new client rather than mutating this one, so the
# admin client stays unscoped and both are safe to keep using.
as_customer = client.on_behalf_of(user.email)

ticket = as_customer.ticket.create(
  title:    "Welcome, #{firstname}!",
  group:    'Users',
  customer: user.email,
  article:  {
    subject:      'Getting started',
    body:         "Hi #{firstname},\n\nyour account is ready.",
    type:         'note',
    content_type: 'text/plain'
  }
)

puts "ticket:       ##{ticket.number} raised as #{user.email}"

# The block form is convenient for a single scoped operation.
own_tickets = client.on_behalf_of(user.email) do |scoped|
  scoped.ticket.all.count
end

puts "the customer can see #{own_tickets} ticket(s) of their own"
