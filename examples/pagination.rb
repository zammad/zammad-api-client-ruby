#!/usr/bin/env ruby
# frozen_string_literal: true

# Every way to page through a collection, and what each one costs in HTTP
# requests.
#
# Collections are lazy: no request happens until you iterate, and only as many
# pages are fetched as you actually consume. The counts printed below are real,
# measured by counting the requests the client logs.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/pagination.rb

require 'zammad_api'
require 'logger'

# A logger that counts outgoing requests, to make the cost of each approach
# visible. Any Logger works here; this one just tallies and discards.
class RequestCounter < Logger
  attr_accessor :count

  def initialize
    super(IO::NULL, level: Logger::DEBUG)
    @count = 0
  end

  def debug(progname = nil)
    message = block_given? ? yield : progname
    @count += 1 if message.to_s.start_with?('Zammad API request:')
    super(message)
  end
end

counter = RequestCounter.new
client  = ZammadAPI::Client.new(
  url:        ENV.fetch('ZAMMAD_URL'),
  http_token: ENV.fetch('ZAMMAD_TOKEN'),
  logger:     counter
)

def measure(counter, label)
  counter.count = 0
  result = yield
  puts format('%<label>-46s %<n>2d request(s)  %<result>s', label: label, n: counter.count, result: result)
end

puts 'Building a collection makes no request at all:'
measure(counter, 'client.ticket.all.per(5)') do
  client.ticket.all.per(5).inspect.sub('ZammadAPI::', '')
end

# A page shorter than the page size means the end of the list. So when the
# total divides evenly by the page size, one extra request is needed to
# discover that there is nothing left: 25 records at 5 per page costs 6
# requests, not 5.
puts "\nIterating everything walks every page until one comes back short:"
measure(counter, '.each — count them all') { "#{client.ticket.all.per(5).count} tickets" }
measure(counter, '.find_each(batch_size: 5)') do
  ids = []
  client.ticket.all.find_each(batch_size: 5) { ids << it.id }
  "#{ids.size} tickets"
end

puts "\nOne array per page, for batched work such as an import:"
measure(counter, '.in_batches(of: 5)') do
  sizes = []
  # The final empty page is not yielded, which is why there are five sizes
  # here but six requests above.
  client.ticket.all.in_batches(of: 5) { sizes << it.size }
  "page sizes #{sizes.inspect}"
end

puts "\nStop early and the remaining pages are never fetched:"
measure(counter, '.first — one record') { client.ticket.all.per(5).first.number }
measure(counter, '.first(3) — fits in one page') { client.ticket.all.per(5).first(3).map(&:id).inspect }
measure(counter, '.first(7) — spills into a second page') { client.ticket.all.per(5).first(7).map(&:id).inspect }
measure(counter, '.lazy.select { … }.first(2)') do
  client.ticket.all.per(5).lazy.select { it.state == 'open' }.first(2).map(&:id).inspect
end
measure(counter, '.find { … } — stops at the first match') do
  client.ticket.all.per(5).find { it.state == 'open' }&.number
end

puts "\nOne specific page, when you are driving the paging yourself:"
measure(counter, '.page(2).per(5).to_a') { client.ticket.all.page(2).per(5).map(&:id).inspect }
measure(counter, '.page(3).per(5).to_a') { client.ticket.all.page(3).per(5).map(&:id).inspect }

puts "\nFilters are query parameters, and stack with the paging:"
measure(counter, ".where(state: 'open')") do
  "#{client.ticket.where(state: 'open').per(5).first(2).size} of them"
end
measure(counter, '.where(...) on an existing collection') do
  "#{client.ticket.all.per(5).where(state: 'open').first(2).size} of them"
end

# Zammad answers a search with a total count, so counting one costs a single
# request. Index endpoints have to be walked page by page.
puts "\nCounting is one request where Zammad can answer it:"
measure(counter, '.search("a").count') { client.ticket.search('a').count }
measure(counter, '.all.per(5).count') { client.ticket.all.per(5).count }

# Zammad caps the page size per endpoint: 100 for /api/v1/tickets, 200 for a
# search, 1000 for the other index endpoints. Asking for more is reduced to
# what the endpoint serves, so a walk stays complete instead of stopping at
# the first capped page.
puts "\nA page size larger than the endpoint allows is clamped, not truncated:"
puts "  all.per(5000)         #{client.ticket.all.per(5000).inspect.sub('ZammadAPI::', '')}"
puts "  search('a').per(5000) #{client.ticket.search('a').per(5000).inspect.sub('ZammadAPI::', '')}"

puts "\nCollections are immutable, so scoping one never disturbs the original:"
base   = client.ticket.all.per(5)
paged  = base.page(3)
scoped = base.where(state: 'open')

puts "  base                #{base.inspect.sub('ZammadAPI::', '')}"
puts "  base.page(3)        #{paged.inspect.sub('ZammadAPI::', '')}"
puts "  paged.equal?(base)  #{paged.equal?(base)}"
puts "  scoped.equal?(base) #{scoped.equal?(base)}"

puts <<~NOTE

  Note for anyone upgrading from 1.x: `each` used to fetch a single page, so
  iterating a collection silently stopped at 100 records. It now walks every
  page. Where you want the old behaviour, ask for one page explicitly with
  `page(1).per(100)`.
NOTE
