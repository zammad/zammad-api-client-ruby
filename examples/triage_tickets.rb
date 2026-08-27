#!/usr/bin/env ruby
# frozen_string_literal: true

# Triages open tickets: escalates the urgent ones, nudges the stale ones.
#
# Demonstrates: search, pattern matching against records, staged changes so
# only modified attributes are sent, and adding an article.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/triage_tickets.rb

require 'zammad_api'
require 'time'

client = ZammadAPI::Client.new(
  url:        ENV.fetch('ZAMMAD_URL'),
  http_token: ENV.fetch('ZAMMAD_TOKEN')
)

STALE_AFTER = 7 * 24 * 60 * 60 # seconds

def stale?(ticket)
  updated = ticket[:updated_at]
  return false if updated.nil?

  Time.now - Time.parse(updated) > STALE_AFTER
end

# `lazy` stops fetching as soon as we stop consuming, so a large result set
# does not have to be downloaded in full.
candidates = client.ticket.search(query: 'state.name:open').lazy.first(200)

escalated = 0
nudged    = 0

candidates.each do |ticket|
  # Records implement `deconstruct_keys`, so they work with case/in — including
  # against nested attributes.
  case ticket
  in { priority: '3 high', owner_id: 1 } # 1 is Zammad's "-" (unassigned)
    puts "unassigned and high priority: ##{ticket.number} #{ticket.title}"
    escalated += 1

  in { state: 'open', title: String => title } if stale?(ticket)
    puts "stale: ##{ticket.number} #{title}"

    # Only the attributes that changed are sent on save.
    ticket.priority = '3 high'
    raise 'expected a staged change' if !ticket.changed?

    ticket.save
    ticket.article(
      subject:  'Automated follow-up',
      body:     "No activity for over #{STALE_AFTER / 86_400} days; priority raised.",
      type:     'note',
      internal: true
    )
    nudged += 1

  else
    next
  end
end

puts "\n#{escalated} ticket(s) flagged, #{nudged} nudged."
