#!/usr/bin/env ruby
# frozen_string_literal: true

# Syncs tickets from a worker pool that shares a single client.
#
# A client is immutable once built, so one instance is safe to share between
# threads: no locking, no client per thread, and `on_behalf_of` scoping in one
# thread cannot leak into another. It is the same reason one client works as a
# Rails initializer constant used from every background worker:
#
#   # config/initializers/zammad.rb
#   ZAMMAD = ZammadAPI::Client.new(
#     url:        Rails.application.credentials.zammad_url,
#     http_token: Rails.application.credentials.zammad_token,
#     logger:     Rails.logger
#   )
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/concurrent_sync.rb

require 'zammad_api'

WORKERS = 4

client = ZammadAPI::Client.from_env

# Collect the work first; `first` stops paginating once it has enough.
queue = Queue.new
client.ticket.all.first(40).each { queue << it.id }
queue.close # so a worker draining an empty queue stops instead of blocking

results = Queue.new

workers = Array.new(WORKERS) do
  Thread.new do
    # Every worker shares this one client. Nothing about it is mutated by
    # making a request, so there is nothing to synchronise.
    while (id = queue.pop)
      results << begin
        client.ticket.find(id)
        :ok
      rescue ZammadAPI::Error => e
        # Transient failures were already retried, so anything arriving here
        # is worth reporting rather than trying again.
        warn "ticket #{id}: #{e.class}"
        :failed
      end
    end
  end
end

workers.each(&:join)

tally = Hash.new(0)
tally[results.pop] += 1 until results.empty?

puts "synced #{tally[:ok]}, failed #{tally[:failed]}"
