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
measure(counter, 'client.ticket.all(per_page: 5)') do
  collection = client.ticket.all(per_page: 5)
  collection.inspect.sub('ZammadAPI::', '')
end

# A page shorter than per_page means the end of the list. So when the total
# divides evenly by per_page, one extra request is needed to discover that
# there is nothing left: 25 records at 5 per page costs 6 requests, not 5.
puts "\nIterating everything walks every page until one comes back short:"
measure(counter, '.each — count them all') { "#{client.ticket.all(per_page: 5).count} tickets" }
measure(counter, '.map(&:id).size — same traversal') { client.ticket.all(per_page: 5).map(&:id).size }

puts "\nOne array per page, for batched work such as an import:"
measure(counter, '.each_page') do
  sizes = []
  # The final empty page is not yielded, which is why there are five sizes
  # here but six requests above.
  client.ticket.all(per_page: 5).each_page { sizes << it.size }
  "page sizes #{sizes.inspect}"
end

puts "\nStop early and the remaining pages are never fetched:"
measure(counter, '.first — one record') { client.ticket.all(per_page: 5).first.number }
measure(counter, '.first(3) — fits in one page') { client.ticket.all(per_page: 5).first(3).map(&:id).inspect }
measure(counter, '.first(7) — spills into a second page') { client.ticket.all(per_page: 5).first(7).map(&:id).inspect }
measure(counter, '.lazy.select { … }.first(2)') do
  client.ticket.all(per_page: 5).lazy.select { it.state == 'open' }.first(2).map(&:id).inspect
end
measure(counter, '.find { … } — stops at the first match') do
  client.ticket.all(per_page: 5).find { it.state == 'open' }&.number
end

puts "\nOne specific page, when you are driving the paging yourself:"
measure(counter, '.page(2, per_page: 5).to_a') { client.ticket.all.page(2, per_page: 5).map(&:id).inspect }
measure(counter, '.page(3, per_page: 5).to_a') { client.ticket.all.page(3, per_page: 5).map(&:id).inspect }

puts "\nIndexing fetches just that record, wherever it is in the list:"
measure(counter, 'collection[0]') { client.ticket.all[0]&.number }
measure(counter, 'collection[12]') { client.ticket.all[12]&.number }

puts "\nExtra query parameters, passed straight to Zammad:"
measure(counter, '.where(state: "open") via all(**query)') do
  "#{client.ticket.all(per_page: 5, state: 'open').first(2).size} of them"
end
measure(counter, '.where(...) on an existing collection') do
  "#{client.ticket.all(per_page: 5).where(state: 'open').first(2).size} of them"
end

puts "\nCollections are immutable, so scoping one never disturbs the original:"
base   = client.ticket.all(per_page: 5)
paged  = base.page(3)
scoped = base.where(state: 'open')

puts "  base.current_page   #{base.current_page.inspect}   (still unpaged)"
puts "  paged.current_page  #{paged.current_page.inspect}"
puts "  paged.equal?(base)  #{paged.equal?(base)}"
puts "  scoped.equal?(base) #{scoped.equal?(base)}"

puts <<~NOTE

  Note for anyone upgrading from 1.x: `each` used to fetch a single page, so
  iterating a collection silently stopped at 100 records. It now walks every
  page. Where you want the old behaviour, ask for one page explicitly with
  `page(1, per_page: 100)`.
NOTE
