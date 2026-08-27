#!/usr/bin/env ruby
# frozen_string_literal: true

# Shows how to handle every failure this gem can raise.
#
# Demonstrates: the error hierarchy, `RateLimitError#retry_after`,
# `server_message` for Zammad's own wording, and that a proxy error page does
# not turn into a JSON parse failure.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/error_handling.rb

require 'zammad_api'

# Configuration is validated up front, before any request is made.
begin
  ZammadAPI::Client.new(url: 'not-a-url', http_token: 'x')
rescue ZammadAPI::ConfigurationError => e
  puts "config rejected early: #{e.message}"
end

client = ZammadAPI::Client.new(
  url:        ENV.fetch('ZAMMAD_URL'),
  http_token: ENV.fetch('ZAMMAD_TOKEN')
)

# A realistic wrapper: retry what is worth retrying, give up on what is not.
def fetch_ticket(client, id, attempts: 3)
  last = attempts - 1

  attempts.times do |attempt|
    return client.ticket.find(id)
  rescue ZammadAPI::NotFoundError
    # The record does not exist. Not worth retrying.
    return nil
  rescue ZammadAPI::AuthenticationError, ZammadAPI::AuthorizationError => e
    # Credentials or permissions: retrying will not help, fail loudly.
    abort "cannot continue: #{e.message}"
  rescue ZammadAPI::RateLimitError => e
    raise if attempt == last

    # Zammad tells us how long to wait; honour it.
    wait = e.retry_after || 5
    warn "rate limited, sleeping #{wait}s"
    sleep wait
  rescue ZammadAPI::TimeoutError, ZammadAPI::ConnectionError => e
    raise if attempt == last

    warn "transient transport failure (#{e.class}), retrying"
  end
end

puts "existing ticket:  #{fetch_ticket(client, 1)&.number || 'not found'}"
puts "missing ticket:   #{fetch_ticket(client, 0).inspect}"

# Validation failures carry Zammad's own message and the offending payload.
begin
  client.group.create({})
rescue ZammadAPI::ValidationError => e
  puts "validation:       #{e.server_message}"
  puts "  status          #{e.status}"
  puts "  body            #{e.body.inspect}"
  puts "  operation       #{e.operation}"
  puts "  resource        #{e.resource_class}"
end

# Rescue by category when the specific class does not matter.
begin
  client.ticket.find(0)
rescue ZammadAPI::ClientError => e     # any 4xx
  puts "client error:     #{e.status}"
rescue ZammadAPI::ServerError => e     # any 5xx, including an HTML proxy page
  puts "server error:     #{e.status}"
rescue ZammadAPI::TransportError => e  # never reached the server
  puts "transport error:  #{e.message}"
end

# Or catch everything from this gem in one place.
begin
  client.ticket.find(0)
rescue ZammadAPI::Error => e
  puts "any gem error:    #{e.class}"
end
