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
#   2. one whole response per block call, numbered or not
#   3. an explicit page loop that can resume where it left off
#   4. the same, throttled between batches
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/manual_batches.rb

require 'zammad_api'
require 'fileutils'
require 'tmpdir'

client = ZammadAPI::Client.from_env

PER_PAGE    = 5
CURSOR_FILE = ENV.fetch('CURSOR_FILE', File.join(Dir.tmpdir, 'zammad_batch_cursor'))

# 1. Pull one page at a time -------------------------------------------------
#
# `in_batches` without a block returns an Enumerator, so you can ask for the
# next page when you are ready for it instead of being called back. Nothing is
# fetched until `next`, and each `next` costs exactly one request.

puts '1. Pull pages on demand'

pages = client.ticket.all.in_batches(of: PER_PAGE)

2.times do
  batch = pages.next
  puts "   pulled #{batch.size} tickets: #{batch.map(&:id).inspect}"
rescue StopIteration
  puts '   no more pages'
  break
end

puts "   stopped after two pages; the rest was never fetched\n\n"

# 2. A batch at a time -------------------------------------------------------
#
# `in_batches` hands the whole response to the block, so the page size is the
# batch size. Without a block it is an Enumerator, so Ruby's `with_index`
# numbers the batches as they arrive - for a progress line, a log prefix, or
# a checkpoint every nth batch.

puts '2. One response at a time, numbered'

client.ticket.all.in_batches(of: PER_PAGE).with_index do |batch, index|
  puts "   batch #{index}: #{batch.size} tickets (ids #{batch.first.id}..#{batch.last.id})"
end

# Drop `with_index` where the number is not interesting.

puts '   ... and the same without the numbering'

client.ticket.all.in_batches(of: PER_PAGE) do |batch|
  puts "   batch of #{batch.size} tickets (ids #{batch.first.id}..#{batch.last.id})"
end
puts

# 3. An explicit, resumable page loop ---------------------------------------
#
# When a job must survive being interrupted, own the page number and persist
# it. A page shorter than the page size means the list is exhausted.

puts '3. Resumable page loop'

start_page = File.exist?(CURSOR_FILE) ? Integer(File.read(CURSOR_FILE).strip) : 1
puts "   resuming at page #{start_page} (cursor: #{CURSOR_FILE})"

tickets    = client.ticket.all
page       = start_page
processed  = 0
pages_done = 0

loop do
  batch = tickets.page(page, of: PER_PAGE).to_a
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

MAX_RATE_LIMIT_RETRIES = 5

page = 1
2.times do
  attempt = 0

  # Bounded on purpose: an instance that keeps returning 429 would otherwise
  # make this loop sleep and retry forever with no way out.
  batch = begin
    tickets.page(page, of: PER_PAGE).to_a
  rescue ZammadAPI::RateLimitError => e
    attempt += 1
    raise if attempt > MAX_RATE_LIMIT_RETRIES

    wait = e.retry_after || 5
    puts "   rate limited, waiting #{wait}s (attempt #{attempt}/#{MAX_RATE_LIMIT_RETRIES})"
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

    each / find_each        the loop is yours and runs to completion
    in_batches              you want one whole response at a time
    in_batches.next         you want to pull batches as a consumer is ready
    in_batches.with_index   you want the batches numbered as they arrive
    page(n, of: m)          the page number must be persisted, retried or skipped
NOTE
