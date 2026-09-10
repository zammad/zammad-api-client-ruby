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

# A ticket title is whatever the customer typed, and a spreadsheet treats a
# cell starting with =, +, -, @, tab or CR as a formula rather than text. A
# title of `=1+1` would be evaluated on open, and worse ones can call out to
# the network, so prefix an apostrophe to force every exported cell to text.
FORMULA_PREFIX = /\A[=+\-@\t\r]/

def csv_safe(value)
  text = value.to_s
  FORMULA_PREFIX.match?(text) ? "'#{text}" : text
end

CSV.open(destination, 'w') do |csv|
  csv << %w[id number title state priority group customer created_at]

  # `each` walks every page; nothing is loaded until it is iterated, and
  # `each_page` lets us report progress per batch rather than per record.
  export_client.ticket.all(per_page: 100).each_page do |tickets|
    tickets.each do |ticket|
      csv << [
        ticket.fetch(:id),        # must exist; raises KeyError otherwise
        csv_safe(ticket.number),
        csv_safe(ticket.title),
        csv_safe(ticket.state),   # present because requests expand by default
        csv_safe(ticket.priority),
        csv_safe(ticket.group),
        csv_safe(ticket.customer),
        csv_safe(ticket.created_at)
      ]
    end

    exported += tickets.size
    warn "exported #{exported} tickets..."
  end
end

puts "Wrote #{exported} tickets to #{destination}"
