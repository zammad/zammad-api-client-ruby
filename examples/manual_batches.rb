#!/usr/bin/env ruby
# frozen_string_literal: true

# Driving pagination yourself, rather than letting `each` walk the pages.
#
# Useful when the loop is not yours to own: a job that has to checkpoint and
# resume, a throttled importer, or a producer handing batches to a queue.
#
# Four approaches, in increasing order of control:
#
#   1. pull one page at a time from an Enumerator
#   2. fixed-size record batches, independent of the API page size
#   3. an explicit page loop that can resume where it left off
#   4. the same, throttled between batches
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/manual_batches.rb

require 'zammad_api'
require 'fileutils'
require 'tmpdir'

client = ZammadAPI::Client.new(
  url:        ENV.fetch('ZAMMAD_URL'),
  http_token: ENV.fetch('ZAMMAD_TOKEN')
)

PER_PAGE    = 5
CURSOR_FILE = ENV.fetch('CURSOR_FILE', File.join(Dir.tmpdir, 'zammad_batch_cursor'))

# 1. Pull one page at a time -------------------------------------------------
#
# `each_page` without a block returns an Enumerator, so you can ask for the
# next page when you are ready for it instead of being called back. Nothing is
# fetched until `next`, and each `next` costs exactly one request.

puts '1. Pull pages on demand'

pages = client.ticket.all(per_page: PER_PAGE).each_page

2.times do
  batch = pages.next
  puts "   pulled #{batch.size} tickets: #{batch.map(&:id).inspect}"
rescue StopIteration
  puts '   no more pages'
  break
end

puts "   stopped after two pages; the rest was never fetched\n\n"

# 2. Fixed-size record batches ----------------------------------------------
#
# Page size is an API concern; your batch size is a processing concern. Slice
# the record enumerator to decouple them, e.g. fetch 5 per request but commit
# 12 at a time.

puts '2. Batches of 12 records, fetched 5 per request'

client.ticket.all(per_page: PER_PAGE).each.each_slice(12).with_index(1) do |batch, index|
  puts "   batch #{index}: #{batch.size} tickets (ids #{batch.first.id}..#{batch.last.id})"
end
puts

# 3. An explicit, resumable page loop ---------------------------------------
#
# When a job must survive being interrupted, own the page number and persist
# it. A page shorter than per_page means the list is exhausted.

puts '3. Resumable page loop'

start_page = File.exist?(CURSOR_FILE) ? Integer(File.read(CURSOR_FILE).strip) : 1
puts "   resuming at page #{start_page} (cursor: #{CURSOR_FILE})"

page       = start_page
processed  = 0
pages_done = 0

loop do
  batch = client.ticket.all.page(page, per_page: PER_PAGE).to_a
  break if batch.empty?

  processed  += batch.size
  pages_done += 1
  puts "   page #{page}: #{batch.size} tickets"

  # Checkpoint only after the batch is safely handled, so an interrupted run
  # repeats a batch rather than skipping one.
  File.write(CURSOR_FILE, page + 1)

  break if batch.size < PER_PAGE # a short page is the last page

  page += 1
end

puts "   processed #{processed} tickets across #{pages_done} page(s)"
FileUtils.rm_f(CURSOR_FILE)
puts "   cursor cleared\n\n"

# 4. Throttled batches -------------------------------------------------------
#
# Same loop, pacing itself. `RateLimitError#retry_after` handles the case where
# Zammad pushes back anyway.

puts '4. Throttled loop (2 pages, 0.2s apart)'

page = 1
2.times do
  batch = begin
    client.ticket.all.page(page, per_page: PER_PAGE).to_a
  rescue ZammadAPI::RateLimitError => e
    wait = e.retry_after || 5
    puts "   rate limited, waiting #{wait}s"
    sleep wait
    retry
  end

  break if batch.empty?

  puts "   page #{page}: #{batch.map(&:id).inspect}"
  page += 1
  sleep 0.2
end

puts <<~NOTE

  Which to reach for:

    each / each_page   the loop is yours and runs to completion
    each_page.next     you want to pull batches as a consumer is ready
    each.each_slice(n) batch size should not be tied to the API page size
    page(n, per_page:) the page number must be persisted, retried or skipped
NOTE
