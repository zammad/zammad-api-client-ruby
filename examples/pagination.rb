#!/usr/bin/env ruby
# frozen_string_literal: true

# Every way to read a collection, and what each one costs.
#
# Collections are lazy: nothing is fetched until you iterate, and only the
# pages you actually consume are fetched. 100 records per request by default.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/pagination.rb

require 'zammad_api'

client  = ZammadAPI::Client.from_env
tickets = client.ticket.all # no request yet

# Walk every record. Pages are fetched as the iteration reaches them, so only
# one page is ever held in memory.
seen = 0
tickets.each { seen += 1 }
puts "each               #{seen} tickets, one request per page"

# The same walk with the page size chosen for the job at hand.
ids = []
tickets.find_each(batch_size: 50) { ids << it.id }
puts "find_each          #{ids.size} tickets, 50 per request"

# One whole page per block call, for work that batches: an import, a bulk
# insert, a push onto a queue.
sizes = []
tickets.in_batches(of: 50) { sizes << it.size }
puts "in_batches         pages of #{sizes.inspect}"

# Stop early and the remaining pages are never fetched.
puts "first(3)           #{tickets.first(3).map(&:id).inspect}, one request"
puts "lazy.select        #{tickets.lazy.select { it.state == 'open' }.first(2).map(&:id).inspect}"
puts "detect             ##{tickets.detect { it.state == 'open' }&.number}, stops at the match"

# One specific page, when you are driving the paging yourself.
puts "page(2, of: 10)    #{tickets.page(2, of: 10).map(&:id).inspect}"

# Filters are Zammad query parameters, and compose with all of the above.
puts "where(state:)      #{client.ticket.where(state: 'open').first(5).size} open tickets"

# Counting a search is one request, because Zammad answers it with a total.
# An index endpoint has to be walked page by page.
puts "search.count       #{client.ticket.search('state.name:open').count}, one request"
puts "empty?             #{client.ticket.where(state: 'merged').empty?}, asks for a single record"

# `where` and `page` return a new collection, so scoping one never disturbs
# the original.
puts "immutable          #{tickets.page(2).equal?(tickets)}"

puts <<~NOTE

  Upgrading from 1.x: `each` used to fetch a single page, so iterating a
  collection silently stopped at 100 records. It now walks every page. Ask
  for one page explicitly with `page(1, of: 100)` where that is what you
  wanted.
NOTE
