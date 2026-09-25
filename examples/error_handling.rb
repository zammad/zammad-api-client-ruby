#!/usr/bin/env ruby
# frozen_string_literal: true

# What to rescue, and what the client has already handled for you.
#
# Timeouts, connection failures and the transient statuses (429, 500, 502,
# 503, 504) are retried with backoff on GET, PUT and DELETE before any error
# reaches your code, so what is left to handle is what only you can decide
# about: a missing record, a rejected attribute, bad credentials.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/error_handling.rb

require 'zammad_api'

# Options are validated up front, before any request is made.
begin
  ZammadAPI::Client.new(url: 'not-a-url', http_token: 'x')
rescue ZammadAPI::ConfigurationError => e
  puts "rejected early:   #{e.message}"
end

client = ZammadAPI::Client.from_env

# A missing record is a decision to make, not a failure to retry.
ticket = begin
  client.ticket.find(0)
rescue ZammadAPI::NotFoundError
  nil
end

puts "missing ticket:   #{ticket.inspect}"

# A rejected attribute (422) makes `save` return false and leaves the reason
# on the record, so branching needs no begin/rescue.
group = client.group.new(name: '')

if group.save
  puts "created group:    #{group.id}"
else
  puts "rejected save:    #{group.error.status} #{group.error.server_message}"
  puts "  body            #{group.error.body.inspect}"
  puts "  operation       #{group.error.operation} on #{group.error.resource_class}"
end

# `create` and `save!` raise instead, which is what a script wants.
begin
  client.group.create(name: '')
rescue ZammadAPI::ValidationError => e
  puts "raised instead:   #{e.class}"
end

# Rescue by category where the exact class does not matter.
begin
  client.ticket.find(0)
rescue ZammadAPI::ClientError => e     # any 4xx
  puts "client error:     #{e.status}"
rescue ZammadAPI::ServerError => e     # any 5xx, including an HTML proxy page
  puts "server error:     #{e.status}"
rescue ZammadAPI::TransportError => e  # never reached the server, retries spent
  puts "transport error:  #{e.message}"
end

# Or catch everything this gem raises in one place.
begin
  client.ticket.find(0)
rescue ZammadAPI::Error => e
  puts "any gem error:    #{e.class}"
end

# Where the defaults do not suit the job, change them once on a derived
# client instead of writing a retry loop around every call.
patient = client.with(retries: 5, retry_interval: 1)

puts "derived client:   #{patient.config.retries} retries, original still #{client.config.retries}"
