#!/usr/bin/env ruby
# frozen_string_literal: true

# Exports every ticket to CSV.
#
# Shows automatic pagination with `in_batches`, and `fetch` for an attribute
# that has to be there. The defaults carry a long export on their own: a
# request times out after 60s, and transient failures are retried with
# backoff before any error reaches this script.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/ticket_report.rb tickets.csv

require 'zammad_api'
require 'csv'

client      = ZammadAPI::Client.from_env
destination = ARGV.fetch(0, 'tickets.csv')
exported    = 0

# A spreadsheet reads a cell starting with =, +, -, @, tab or CR as a formula,
# and a ticket title is whatever the customer typed. An apostrophe keeps every
# exported cell text.
def csv_safe(value)
  text = value.to_s
  text.match?(/\A[=+\-@\t\r]/) ? "'#{text}" : text
end

CSV.open(destination, 'w') do |csv|
  csv << %w[id number title state priority group customer created_at]

  # Nothing is loaded until the block runs, and each call is one page.
  client.ticket.all.in_batches(of: 100) do |tickets|
    tickets.each do |ticket|
      row = [
        ticket.fetch(:id), # raises KeyError if it is missing
        ticket.number,
        ticket.title,
        ticket.state, # present because associations come expanded
        ticket.priority,
        ticket.group,
        ticket.customer,
        ticket.created_at
      ]

      csv << row.map { csv_safe(it) }
    end

    exported += tickets.size
    warn "exported #{exported} tickets..."
  end
end

puts "Wrote #{exported} tickets to #{destination}"
