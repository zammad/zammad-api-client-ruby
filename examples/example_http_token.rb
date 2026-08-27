#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'zammad_api'
require 'logger'

client = ZammadAPI::Client.new(
  url:        'https://you.zammad.com/',
  http_token: 'XXXX',
  timeout:    30,
  logger:     Logger.new($stdout, level: Logger::INFO)
)

separator = '-' * 56

# Create a ticket with its first article.
ticket = client.ticket.create(
  title:    'some new title',
  state:    'new',
  priority: '2 normal',
  owner:    '-',
  customer: 'nicole.braun@zammad.org',
  group:    'Users',
  article:  {
    sender:       'Customer',
    type:         'note',
    subject:      'some subject',
    content_type: 'text/plain',
    body:         "some body\nnext line",
  }
)

puts separator
puts "Ticket has been created: #{ticket.number} - #{ticket.title} at #{ticket.created_at}"

# Fetch it back.
puts separator
ticket = client.ticket.find(ticket.id)
puts "Ticket found on server: #{ticket.number} - #{ticket.title}"

# Add another article.
puts separator
article = ticket.article(type: 'note', subject: 'some subject 2', body: 'some body 2')
puts "Article has been created: #{article.subject} at #{article.created_at}"
puts "Total #{ticket.articles.length} articles now"

# Iterate every open ticket, one page at a time behind the scenes.
puts separator
client.ticket.all.lazy.select { it.state == 'open' }.first(5).each do |open_ticket|
  puts "Open: #{open_ticket.number} - #{open_ticket.title}"
end

# Download the attachments of the first article, if any.
puts separator
ticket.articles.first&.attachments&.each do |attachment|
  puts "Attachment #{attachment.filename} (#{attachment.size} bytes)"
  File.binwrite(attachment.filename, attachment.download)
end

# Errors carry the status and Zammad's own message.
puts separator
begin
  client.ticket.find(0)
rescue ZammadAPI::NotFoundError => e
  puts "Expected failure: #{e.status} - #{e.server_message || e.message}"
rescue ZammadAPI::RateLimitError => e
  puts "Rate limited, retry after #{e.retry_after}s"
end
puts separator
