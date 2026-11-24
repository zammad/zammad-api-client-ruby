#!/usr/bin/env ruby
# frozen_string_literal: true

# Driving pagination yourself, for when the loop is not yours to own: a job
# that has to checkpoint and resume, or a producer feeding a queue.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     bundle exec ruby examples/manual_batches.rb

require 'zammad_api'
require 'fileutils'
require 'tmpdir'

PER_PAGE = 50
CURSOR   = File.join(Dir.tmpdir, 'zammad_batch_cursor')

client  = ZammadAPI::Client.from_env
tickets = client.tickets.all

# 1. Pull a page when you are ready for it -----------------------------------
#
# `in_batches` without a block is an Enumerator: nothing is fetched until
# `next`, and each `next` costs one request.

puts '1. pulling two pages, leaving the rest unfetched'

pages = tickets.in_batches(of: PER_PAGE)

2.times do
  puts "   pulled #{pages.next.size} tickets"
rescue StopIteration
  break
end

# 2. Numbered batches --------------------------------------------------------

puts '2. every batch, numbered'

tickets.in_batches(of: PER_PAGE).with_index do |batch, index|
  puts "   batch #{index}: #{batch.size} tickets"
end

# 3. A resumable page loop ---------------------------------------------------
#
# Own the page number when the job has to survive being interrupted. The
# checkpoint is written once a page is handled, so a rerun repeats at most
# one page. A page number is a position, so this suits a set that only grows:
# tickets are served in id order, and new ones arrive at the end.

puts '3. resumable page loop'

page = File.exist?(CURSOR) ? Integer(File.read(CURSOR)) : 1
puts "   starting at page #{page}"

loop do
  batch = tickets.page(page, per_page: PER_PAGE).to_a
  break if batch.empty?

  puts "   page #{page}: #{batch.size} tickets"

  page += 1
  File.write(CURSOR, page)
end

FileUtils.rm_f(CURSOR)

puts <<~NOTE

  Which to reach for:

    each / find_each        the loop is yours and runs to completion
    in_batches              you want one whole response at a time
    in_batches.next         you want to pull batches as a consumer is ready
    in_batches.with_index   you want the batches numbered as they arrive
    page(n, per_page: m)    the page number must be persisted, retried or skipped

  Pacing is not on this list: the client already backs off and retries a 429.
NOTE
