#!/usr/bin/env ruby
# frozen_string_literal: true

# Triages open tickets: flags the urgent ones, nudges the stale ones.
#
# Shows `search`, pattern matching against records, staged changes so only
# what was modified is sent, and adding an article.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/triage_tickets.rb

require 'zammad_api'
require 'time'

STALE_AFTER = 7 * 24 * 60 * 60 # a week, in seconds

client  = ZammadAPI::Client.from_env
flagged = 0
nudged  = 0

# Oldest first: a search is served newest-updated first, so without the
# order the 200 read would be the freshest, and on an instance with more
# open tickets than that the stale ones would never be looked at. `first`
# stops paginating as soon as it has what it asked for.
client.tickets.search('state.name:open').order(updated_at: :asc).first(200).each do |ticket|
  # Records implement `deconstruct_keys`, so case/in works on them.
  case ticket
  in { priority: '3 high', owner_id: 1 } # 1 is Zammad's "-", i.e. unassigned
    puts "unassigned and high priority: ##{ticket.number} #{ticket.title}"
    flagged += 1

  in { updated_at: String => updated } if Time.now - Time.parse(updated) > STALE_AFTER
    puts "stale: ##{ticket.number} #{ticket.title}"

    ticket.priority = '3 high'
    # Sends the one changed attribute, nothing else. A change Zammad rejects
    # as invalid (a 422) comes back as false rather than raising, so it is
    # checked: an unchecked save carries on as if the priority had been
    # raised. Any other failure, such as a 403, raises.
    if !ticket.save
      warn "  could not raise the priority of ##{ticket.number}: #{ticket.error.message}"
      next
    end

    ticket.add_article(
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

puts "\n#{flagged} ticket(s) flagged, #{nudged} nudged."
