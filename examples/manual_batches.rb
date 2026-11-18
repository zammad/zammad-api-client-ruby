#!/usr/bin/env ruby
# frozen_string_literal: true

# Driving pagination yourself, for when the loop is not yours to own: a job
# that has to checkpoint and resume, or a producer feeding a queue.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/manual_batches.rb

require 'zammad_api'
require 'digest'
require 'fileutils'
require 'tmpdir'

PER_PAGE = 50

client  = ZammadAPI::Client.from_env
tickets = client.tickets.all

# Where the loop in part 3 keeps its checkpoint. A page number says which
# tickets come next only together with the instance it was counted on, the
# list it pages and the size of the pages, so the file is named for all
# three. Under one name for every run, a job stopped at page 4 of one Zammad
# had the next run against another start at page 4 there, with the first
# three pages never read - and remove the first job's checkpoint when it
# finished.
JOB         = Digest::SHA256.hexdigest("#{client.config.url} api/v1/tickets #{PER_PAGE}")[0, 16]
CURSOR      = File.join(Dir.tmpdir, "zammad_batch_cursor_#{JOB}")
NEXT_CURSOR = "#{CURSOR}.next".freeze

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
# Own the page number when the job has to survive being interrupted. The
# loop ends on a page with nothing on it, and not on a page short of
# PER_PAGE: that is the size asked for, and what counts is the size served.
# An instance that serves 25 where 50 were asked for hands back a "short"
# page every time, and a loop that stops on one has stopped after the first
# with the checkpoint cleared. `find_each` and `in_batches` learn the size
# from the first page; here one more request at the end does the same job.
#
# A page number is a position, not a record, so it only resumes where it left
# off while nothing before it goes away. Delete one ticket from a page already
# handled and every later ticket moves up a place: the next page then starts
# one ticket further on, and the ticket that moved into the handled page is
# never seen. New tickets are no trouble here, because this index is served in
# id order and they arrive at the end.
#
# So this loop is for a set that only grows. Where tickets can be deleted
# between two runs of the job, checkpoint the id of the last ticket handled
# instead, and skip up to it on the way back in:
#
#   tickets.find_each.lazy.drop_while { it.id <= last_id }.each { ... }
#
# That reads the earlier pages again, so a ticket deleted while the job was
# down no longer moves the place it picks up from.
#
# It does nothing about a ticket deleted while a walk is under way, and
# neither does anything else here. `find_each` pages by position too: delete
# ticket 1 once page 1 has been read, and page 2 starts one ticket further
# on, with the ticket that moved up into page 1 never handed over. No way of
# reading an index that is paged by position rules that out, and walking
# again does not either: a second walk that tickets are deleted under can
# pass over the same ticket and turn up nothing new. What settles it is a
# walk nothing was deleted during, which the job has to be able to vouch
# for - by holding deletions off while it runs, say - and which turns up
# no ticket it has not handled.

puts '3. resumable page loop'

page = 1

if File.exist?(CURSOR)
  # A checkpoint holds a page number or it holds nothing this loop can use.
  # Said here, rather than left to `Integer` or to `page` to raise about.
  page = Integer(File.read(CURSOR), exception: false)
  abort "   #{CURSOR} does not hold a page number. Remove it to start from page 1." if page.nil? || !page.positive?
end

puts "   starting at page #{page}"

loop do
  batch = tickets.page(page, per_page: PER_PAGE).to_a
  break if batch.empty?

  puts "   page #{page}: #{batch.size} tickets"

  # Checkpoint once the batch is safely handled, so an interrupted run
  # repeats a batch rather than skipping one - on a set nothing is deleted
  # from, see above.
  #
  # Written beside the checkpoint and renamed over it, which replaces it in
  # one step. `File.write` on the checkpoint itself empties the file before
  # it fills it, and a run stopped in between leaves a checkpoint with
  # nothing in it, where the page before was still worth having.
  File.write(NEXT_CURSOR, page + 1)
  File.rename(NEXT_CURSOR, CURSOR)

  page += 1
end

FileUtils.rm_f([CURSOR, NEXT_CURSOR])

puts <<~NOTE

  Which to reach for:

    each / find_each        the loop is yours and runs to completion
    in_batches              you want one whole response at a time
    in_batches.next         you want to pull batches as a consumer is ready
    in_batches.with_index   you want the batches numbered as they arrive
    page(n, per_page: m)    the page number must be persisted, retried or skipped,
                            and nothing is deleted from the set meanwhile

  Pacing is not on this list: the client already backs off and retries a 429,
  so a manual sleep loop only duplicates it.
NOTE
