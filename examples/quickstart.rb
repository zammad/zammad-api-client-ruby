#!/usr/bin/env ruby
# frozen_string_literal: true

# The basics, end to end: create a ticket, read it back, add an article and
# update it.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/quickstart.rb

require 'zammad_api'

client = ZammadAPI::Client.from_env

puts "connected to Zammad #{client.version} as #{client.me.email}"

# Create a ticket together with its first article.
ticket = client.tickets.create(
  title:    'Cannot log in',
  group:    'Users',
  customer: 'nicole.braun@zammad.org',
  article:  {
    subject: 'Cannot log in',
    body:    "Hi,\n\nmy password stopped working.",
    type:    'note'
  }
)

puts "created ##{ticket.number} - #{ticket.title}"

# Read it back. Associations come expanded, so these are plain attribute
# reads rather than further requests.
ticket = client.tickets.find(ticket.id)
puts "state #{ticket.state}, priority #{ticket.priority}, group #{ticket.group}"

# Add another article.
ticket.add_article(subject: 'Update', body: 'Reset link sent.', type: 'note')
puts "#{ticket.articles.size} article(s)"

# Assignments are staged, and `save` sends only what changed. It answers
# false, with the reason in `error`, where Zammad rejects the change.
ticket.priority = '3 high'
puts "sending #{ticket.changes.inspect}"
abort "Zammad rejected the change: #{ticket.error.message}" if !ticket.save

# Collections paginate themselves, and `first` stops as soon as it has enough.
client.tickets.search('state.name:open').first(5).each do |open_ticket|
  puts "open: ##{open_ticket.number} #{open_ticket.title}"
end
