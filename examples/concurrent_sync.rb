#!/usr/bin/env ruby
# frozen_string_literal: true

# Syncs tickets using a worker pool that shares one client.
#
# Demonstrates: a client is immutable after construction, so a single
# instance is safe to share between threads, and `on_behalf_of` scoping in
# one thread cannot leak into another. This is the same reason a memoized
# client works as a Rails initializer constant used from Sidekiq workers:
#
#   # config/initializers/zammad.rb
#   ZAMMAD = ZammadAPI::Client.new(
#     url:        Rails.application.credentials.zammad_url,
#     http_token: Rails.application.credentials.zammad_token,
#     logger:     Rails.logger,
#     timeout:    15
#   )
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/concurrent_sync.rb

require 'zammad_api'
require 'logger'

WORKERS = 4

client = ZammadAPI::Client.new(
  url:        ENV.fetch('ZAMMAD_URL'),
  http_token: ENV.fetch('ZAMMAD_TOKEN'),
  timeout:    15,
  logger:     Logger.new($stderr, level: Logger::WARN)
)

# Collect the work up front; `first` stops paginating once it has enough.
ticket_ids = client.ticket.all.lazy.map(&:id).first(40)
queue      = Queue.new
ticket_ids.each { queue << it }

results = Queue.new

workers = Array.new(WORKERS) do |index|
  Thread.new do
    # Each worker shares the same client object. No locking is needed: nothing
    # about the client is mutated by making a request.
    loop do
      id = begin
        queue.pop(true)
      rescue ThreadError # the queue is empty
        break
      end

      begin
        ticket = client.ticket.find(id)
        results << [:ok, id, ticket.title]
      rescue ZammadAPI::TransportError => e
        results << [:retry, id, e.class.to_s]
      rescue ZammadAPI::Error => e
        results << [:failed, id, e.message]
      end
    end
    warn "worker #{index} done"
  end
end

workers.each(&:join)

tally = { ok: 0, retry: 0, failed: 0 }
tally[results.pop.first] += 1 until results.empty?

puts "synced #{tally[:ok]}, retryable #{tally[:retry]}, failed #{tally[:failed]}"
