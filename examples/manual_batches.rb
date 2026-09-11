#!/usr/bin/env ruby
# frozen_string_literal: true

# Driving pagination yourself, for when the loop is not yours to own: a job
# that has to checkpoint and resume, or a producer feeding a queue.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/manual_batches.rb

require 'zammad_api'
require 'fileutils'
require 'tmpdir'

PER_PAGE = 50
CURSOR   = File.join(Dir.tmpdir, 'zammad_batch_cursor')

client  = ZammadAPI::Client.from_env
tickets = client.ticket.all

# 1. Pull a page when you are ready for it -----------------------------------
#
# `in_batches` without a block is an Enumerator: nothing is fetched until
# `next`, and each `next` costs exactly one request.

puts '1. pulling two pages, leaving the rest unfetched'

pages = tickets.in_batches(of: PER_PAGE)

2.times do
  puts "   pulled #{pages.next.size} tickets"
rescue StopIteration
  break
end

# 2. Numbered batches --------------------------------------------------------
#
# `with_index` is Ruby's own, and works for the same reason: an Enumerator.

puts '2. every batch, numbered'

tickets.in_batches(of: PER_PAGE).with_index do |batch, index|
  puts "   batch #{index}: #{batch.size} tickets"
end

# 3. A resumable page loop ---------------------------------------------------
#
# Own the page number when the job has to survive being interrupted. A page
# shorter than the page size is the last one.

puts '3. resumable page loop'

page = File.exist?(CURSOR) ? Integer(File.read(CURSOR)) : 1
puts "   starting at page #{page}"

loop do
  batch = tickets.page(page, of: PER_PAGE).to_a
  break if batch.empty?

  puts "   page #{page}: #{batch.size} tickets"

  # Checkpoint once the batch is safely handled, so an interrupted run
  # repeats a batch rather than skipping one.
  File.write(CURSOR, page + 1)
  break if batch.size < PER_PAGE

  page += 1
end

FileUtils.rm_f(CURSOR)

puts <<~NOTE

  Which to reach for:

    each / find_each        the loop is yours and runs to completion
    in_batches              you want one whole response at a time
    in_batches.next         you want to pull batches as a consumer is ready
    in_batches.with_index   you want the batches numbered as they arrive
    page(n, of: m)          the page number must be persisted, retried or skipped

  Pacing is not on this list: the client already backs off and retries a 429,
  so a manual sleep loop only duplicates it.
NOTE
