#!/usr/bin/env ruby
# frozen_string_literal: true

# Exports every ticket to CSV.
#
# Demonstrates: automatic pagination, `each_page` for batching, a derived
# client with a longer timeout for a long-running job, and `fetch` for
# attributes that must be present.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/ticket_report.rb tickets.csv

require 'zammad_api'
require 'csv'
require 'logger'

client = ZammadAPI::Client.new(
  url:        ENV.fetch('ZAMMAD_URL'),
  http_token: ENV.fetch('ZAMMAD_TOKEN'),
  logger:     Logger.new($stderr, level: Logger::WARN)
)

# A bulk export can run for a while, so derive a client with a longer timeout
# and more patience for transient failures. The original client is untouched.
export_client = client.with(timeout: 300, retries: 5)

destination = ARGV.fetch(0, 'tickets.csv')
exported    = 0

CSV.open(destination, 'w') do |csv|
  csv << %w[id number title state priority group customer created_at]

  # `each` walks every page; nothing is loaded until it is iterated, and
  # `each_page` lets us report progress per batch rather than per record.
  export_client.ticket.all(per_page: 100).each_page do |tickets|
    tickets.each do |ticket|
      csv << [
        ticket.fetch(:id),        # must exist; raises KeyError otherwise
        ticket.number,
        ticket.title,
        ticket.state,             # present because requests expand by default
        ticket.priority,
        ticket.group,
        ticket.customer,
        ticket.created_at
      ]
    end

    exported += tickets.size
    warn "exported #{exported} tickets..."
  end
end

puts "Wrote #{exported} tickets to #{destination}"
