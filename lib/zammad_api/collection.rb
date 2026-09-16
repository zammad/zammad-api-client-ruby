# frozen_string_literal: true

require_relative 'duplicate_keys'
require_relative 'errors'

module ZammadAPI
  # A lazily fetched, automatically paginated list of records.
  #
  # Nothing is requested until the collection is iterated. {#where} and
  # {#page} return new collections, so a collection can be built up in
  # steps and shared without being disturbed.
  #
  # {#each} walks every page until the server runs out of records, so it is
  # safe to iterate a collection larger than one page. Combine it with
  # +Enumerable+ methods such as +first+, +lazy+ or +find+ to stop early
  # without downloading everything.
  #
  # @example Iterate every ticket
  #   client.ticket.all.each { |ticket| puts ticket.title }
  #
  # @example Narrow to matches, then stop after the first five
  #   client.ticket.search('state.name:open').first(5)
  #
  # @example Work in batches, e.g. for an import
  #   client.ticket.all.in_batches(of: 50) { |tickets| import(tickets) }
  #
  # @example One explicit page
  #   client.ticket.all.page(2, of: 50).to_a
  class Collection
    include Enumerable

    # Records fetched per request, unless a call asks for another size.
    DEFAULT_PER_PAGE = 100

    # Query parameters this collection owns. Passing them to {#where} would be
    # silently overridden, so they are rejected instead.
    #
    # +query+ is in the list because it is the search term {ResourceProxy#search}
    # set: merging another one replaced it, so
    # +search('login failure').where(query: 'anything')+ searched for
    # "anything" and said nothing about it.
    RESERVED_QUERY_KEYS = %i[page per_page expand only_total_count query].freeze
    private_constant :RESERVED_QUERY_KEYS

    # @api private
    def initialize(transport:, resource_class:, path:, operation:, max_per_page:, filterable:, filter_hint:, query: {}, per_page: DEFAULT_PER_PAGE, page: nil, countable: false)
      @transport      = transport
      @resource_class = resource_class
      @path           = path
      @operation      = operation
      @query          = query
      @max_per_page   = max_per_page
      @filterable     = filterable
      @filter_hint    = filter_hint
      @per_page       = clamp_per_page(per_page)
      @page           = page
      @countable      = countable
    end

    # Yields every record, fetching further pages as needed.
    #
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    def each(&block)
      return to_enum(:each) if !block

      in_batches { |records| records.each(&block) }
      self
    end

    # Yields every record, like {#each}, with the page size set inline.
    #
    # @param batch_size [Integer, nil] records fetched per request
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    def find_each(batch_size: nil, &block)
      return to_enum(:find_each, batch_size: batch_size) if !block
      return with(per_page: page_size!(batch_size, 'batch_size')).find_each(&block) if batch_size

      each(&block)
    end

    # Yields one array of records per page.
    #
    # A batch is one response: what a request returned is what the block gets,
    # so +of+ is what sizes it. For groups of a size the API knows nothing
    # about, slice the records instead: +find_each.each_slice(12)+.
    #
    # @param of [Integer, nil] records fetched per request
    # @yieldparam records [Array<Resources::Base>]
    # @return [Enumerator] when no block is given
    def in_batches(of: nil, &block)
      return to_enum(:in_batches, of: of) if !block
      return with(per_page: page_size!(of, 'of')).in_batches(&block) if of

      walk(&block)
      self
    end

    # Returns a new collection limited to a single page.
    #
    # +of+ decides how big that page is, and so which records it holds:
    # +page(2, of: 50)+ is records 51 to 100. A size larger than the endpoint
    # serves is refused rather than reduced, because reducing it moves the
    # page: +page(3, of: 500)+ against an endpoint capping at 100 was sent as
    # +page=3&per_page=100+ and answered with records 201 to 300 instead of
    # 1001 to 1500. A job that checkpoints a page number then re-read what it
    # had already handled and never reached the rest.
    #
    # @example
    #   client.ticket.all.page(2, of: 50).to_a
    #
    # @param number [Integer] one-based page number
    # @param of [Integer, nil] records on the page, {DEFAULT_PER_PAGE} by default
    # @return [Collection]
    # @raise [ArgumentError] for a page size the endpoint does not serve
    def page(number, of: nil)
      raise ArgumentError, 'page needs to be a positive integer' if !number.is_a?(Integer) || !number.positive?
      return with(page: number) if of.nil?

      size = positive_integer!(of, 'of')
      raise ArgumentError, "#{@path} serves at most #{@max_per_page} records per page, so page(#{number}, of: #{size}) would be sent as page #{number} of #{@max_per_page} and hold different records. Ask for page(#{number}, of: #{@max_per_page}) or fewer, or walk the records with find_each." if size > @max_per_page

      with(page: number, per_page: size)
    end

    # Returns a new collection with additional query parameters applied.
    #
    # Only parameters the endpoint actually reads are accepted. Zammad drops
    # the ones it does not know rather than refusing them, so
    # +client.user.where(email: 'someone@example.com')+ used to come back as
    # the whole user index and nothing said otherwise - the caller iterated
    # every user believing they had matched one. An endpoint that cannot
    # answer the question has to say so.
    #
    # @param params [Hash] query parameters the endpoint honours
    # @return [Collection]
    # @raise [ArgumentError] for a parameter this collection controls itself,
    #   or one the endpoint would ignore
    # @see ResourceProxy#find_by for looking a record up by attribute value
    def where(**params)
      # Both lists below hold Symbols, while `**params` collects a String key
      # just as happily. Unnormalised, `where('sort_by' => 'name')` failed the
      # second check and reported that the endpoint "ignores sort_by ... That
      # endpoint honours sort_by" in one breath, and `where('page' => 2)`
      # missed the reserved-key check entirely and was refused with a message
      # that never mentioned paging.
      filters = normalized_filters(params)

      reserved = filters.keys & RESERVED_QUERY_KEYS
      raise ArgumentError, "#{reserved.join(', ')} cannot be passed to where: use page, in_batches or find_each for paging, pass a search term to search, and leave expand and only_total_count to the collection" if !reserved.empty?

      ignored = filters.keys - @filterable
      raise ArgumentError, ignored_message(ignored) if !ignored.empty?

      with(query: @query.merge(filters))
    end

    # Reads one or more attributes from every record.
    #
    # Zammad has no way to ask an index endpoint for a subset of the fields, so
    # this shapes the result rather than shrinking the request.
    #
    # @example
    #   client.user.all.pluck(:email)          # => ["a@example.com", ...]
    #   client.ticket.all.pluck(:id, :title)   # => [[1, "Help"], ...]
    #
    # @param keys [Array<Symbol, String>] attribute names
    # @return [Array] one value per record for a single key, one array of
    #   values per record for several
    # @raise [ArgumentError] when no attribute name was given
    def pluck(*keys)
      raise ArgumentError, 'pluck needs at least one attribute name' if keys.empty?
      return map { it[keys.first] } if keys.one?

      map { |record| keys.map { record[it] } }
    end

    # Number of records in this collection.
    #
    # Zammad answers this in one request for a search; every other endpoint
    # has to be walked.
    #
    # @return [Integer]
    def count(*args, &block)
      return super if !args.empty? || block || @page || !@countable

      total_count || super
    end

    # Number of records in this collection.
    #
    # An alias of {#count}, and so the same cost: one request on a search
    # endpoint, a walk of every page on any other.
    #
    # @return [Integer]
    # @see #count
    alias size count

    # @return [Integer]
    # @see #count
    alias length count

    # Whether this collection has no records.
    #
    # Costs one request, which asks for a single record rather than a whole
    # page - except on a collection limited to one page, where the page size
    # decides which records that page holds and so cannot be narrowed.
    #
    # @example
    #   client.ticket.search('state.name:merged').empty?
    #
    # @return [Boolean]
    def empty? = (@page ? self : page(1, of: 1)).first.nil?

    def inspect
      "#<#{self.class.name} #{@resource_class.name} path=#{@path.inspect} per_page=#{@per_page}#{" page=#{@page}" if @page}>"
    end

    private

    def ignored_message(ignored)
      honoured = @filterable.empty? ? 'nothing beyond paging' : @filterable.join(', ')

      "#{@path} ignores #{ignored.join(', ')}, so where would hand back unfiltered records. " \
        "That endpoint honours #{honoured}. #{@filter_hint}"
    end

    def positive_integer!(value, name)
      raise ArgumentError, "#{name} needs a positive integer" if !value.is_a?(Integer) || !value.positive?

      value
    end

    # Re-sizing the page of a collection that {#page} already limited would
    # change which records it holds: `page(3, of: 50)` names records 101 to
    # 150, and re-sizing to 10 behind the caller's back served records 21 to
    # 30 instead - a different answer to the same question, with nothing said
    # about it. The two ways of naming a page cannot both be honoured, so this
    # says so rather than picking one, the way {#where} does.
    def page_size!(value, name)
      size = positive_integer!(value, name)
      raise ArgumentError, "#{name} cannot be combined with page: page(#{@page}, of: #{@per_page}) already named which records this collection holds. Size that page with page(#{@page}, of: #{size}), or slice the records with each_slice(#{size})." if @page

      size
    end

    def walk
      page      = @page || 1
      previous  = nil
      page_size = 0
      seen      = 0
      total     = nil
      loop do
        records, response, digest = fetch(page, @per_page)
        total = response.reported_total if total.nil?
        seen += records.size

        # Before the records are handed over, not after. Yielding first meant
        # an endpoint that ignores `page` had its repeated page imported,
        # queued or written by the block, and only then did the guard that
        # exists to prevent that get to look at it.
        #
        # Whole payloads rather than ids: an endpoint that serves records
        # without an id would compare two empty lists on every page and so
        # report a perfectly good paginator as stuck. A digest rather than the
        # payloads themselves, because holding the previous page across the
        # next fetch doubled a walk's peak memory for a guard that only ever
        # asks whether two pages are equal.
        #
        # The decoded payload, not the bytes it arrived as. Hashing raw_body
        # is cheaper and looks equivalent - identical bytes do mean identical
        # records - but the implication that matters here runs the other way:
        # an endpoint that ignores `page` and re-serializes the same records
        # with a different key order produces different bytes every time, so
        # the guard never fires, and because every page is full neither the
        # short-page break nor the total break fires either. A missed repeat
        # is not a missed error, it is a walk that never ends. `Hash#hash`
        # ignores key order and whitespace, which is exactly the insensitivity
        # this needs - and taking it from the decoded payload rather than from
        # the built records costs nothing extra, because that payload is what
        # the records were built from one line earlier.
        raise PaginationError.build(operation: @operation, page: page, resource_class: @resource_class) if digest == previous

        yield records if !records.empty?

        # A collection limited to a single page never advances.
        break if @page
        break if records.empty?

        # Where the endpoint reported how many records the query has, that is
        # the answer to whether there is another page, and it arrived with the
        # page already fetched. Without it the rule below has to see a short
        # page before it can stop, so every collection smaller than one page -
        # the ticket states, the priorities, most of what a script reads -
        # paid for a second request that could only ever come back empty.
        #
        # Only where the page it arrived with corroborates it, though. This is
        # the one stop condition here not derived from the records the
        # endpoint actually served, and a total that under-reports - a count
        # taken before permission scoping, a stale cache, a proxy rewriting
        # the header - used to end the walk early: 100 of 150 records came
        # back, nothing was raised, and nothing told that result apart from a
        # complete one.
        break if reached_total?(seen, total, records.size, page_size)

        # How big a page this endpoint actually serves, learned from the first
        # one rather than assumed. The requested size is clamped to a per-
        # resource page limit, and where that guess was higher than the
        # server's real cap - a lowered setting, a custom deployment, an
        # endpoint whose cap was never this generous - every page came back
        # short and the walk stopped on page one with a truncated result and
        # nothing to show for it.
        page_size = records.size if page_size.zero?
        break if records.size < page_size

        previous = digest
        page += 1
      end
    end

    def with(page: @page, per_page: @per_page, query: @query)
      self.class.new(
        transport:      @transport,
        resource_class: @resource_class,
        path:           @path,
        operation:      @operation,
        max_per_page:   @max_per_page,
        filterable:     @filterable,
        filter_hint:    @filter_hint,
        query:          query,
        per_page:       per_page,
        page:           page,
        countable:      @countable
      )
    end

    # Normalises the keys, refusing two spellings of one parameter rather than
    # letting the normalisation merge them.
    #
    # Normalising is exactly what hid the collision: `sort_by` and `'sort_by'`
    # became one key here, last one winning, and the request went out carrying
    # a value the caller never saw dropped. The reserved-key and ignored-key
    # checks in `where` read the collapsed hash too, so nothing else was going
    # to notice either.
    #
    # Nested too, because `condition` - the structured parameter the search
    # endpoints read, and one {ResourceProxy::SEARCH_QUERY_KEYS} lists so that
    # `where` accepts it - is a Hash. {Transport.stringify_query} would refuse
    # the pair eventually, but not until the collection is enumerated, and
    # every other refusal `where` makes happens at the call that wrote it.
    #
    # @raise [ArgumentError] for two keys that name the same parameter
    def normalized_filters(params, prefix = nil)
      DuplicateKeys
        .normalize(params, prefix: prefix) { it.to_s.to_sym }
        .to_h { |name, value| [name, nested_filters(name, value, prefix)] }
    end

    # A Hash filter is normalised the same way, one level down.
    def nested_filters(name, value, prefix)
      return value if !value.is_a?(Hash)

      normalized_filters(value, prefix ? "#{prefix}[#{name}]" : name.to_s)
    end

    # Fetches one page and the digest the repeated-page guard compares.
    #
    # @return [Array(Array<Resources::Base>, Response, Integer)] the records,
    #   the response they came in - which carries what the endpoint said about
    #   the size of the whole result - and the digest
    def fetch(page, per_page)
      response = @transport.get(
        @path,
        operation:      @operation,
        resource_class: @resource_class,
        query:          @query.merge(page: page, per_page: per_page)
      )
      decoded = response.decoded(:array, operation: @operation, resource_class: @resource_class)
      # The digest for the repeated-page guard is taken here, from the decoded
      # payload, which is the one structure that has everything the guard needs
      # and is already in hand. See the guard in `walk` for why it is this and
      # not the records or the raw body.
      [decoded.map { @resource_class.from_response(@transport, it) }, response, decoded.hash]
    end

    # Whether the endpoint's own count says there is nothing after this page,
    # and the page agrees with it.
    #
    # A method rather than the guard written inline, so that the nil check
    # narrows: `total` is assigned inside the loop, and the type checker will
    # not narrow a local it sees reassigned there.
    #
    # Two conditions, because a count can be wrong in both directions and only
    # one of them is safe:
    #
    # * The page came back short of the size this endpoint serves, so it had
    #   no more to give. A full page means it may still be serving, whatever
    #   its count claims, and the cost of asking is one request that comes
    #   back empty.
    # * Exactly as many records were seen as the count names. Seeing more
    #   means the endpoint has already contradicted its own header, and a
    #   count contradicted once is not one to end a walk on - the remaining
    #   stop conditions, which read the records themselves, take over.
    #
    # An over-reported total still costs nothing: the walk runs on and stops
    # on the empty page, which is what it did before there was a header to
    # read.
    def reached_total?(seen, total, page_records, page_size)
      return false if total.nil? || seen != total

      # Short of what this endpoint serves, which is not the same as short of
      # what was asked for. The two differ wherever the server's cap is lower
      # than the request - a lowered api_pagination_limit, a custom deployment
      # - and reading the requested size there made every page look like the
      # last one: an endpoint serving 2 per page against a request for 100,
      # with a total under-reporting 2 of 3, ended the walk on page one with 2
      # records and nothing raised. That is the failure the corroboration
      # exists to prevent, reached one page further in.
      #
      # Page one is still read against the requested size, because nothing has
      # shown what the endpoint serves yet. What that leaves is the case where
      # the cap is lower AND the total under-reports AND the short first page
      # is all there is: only a second request tells that apart from a
      # complete result, and paying for one on every collection smaller than a
      # page is the cost reading the total is here to avoid.
      page_records < (page_size.zero? ? @per_page : page_size)
    end

    # @return [Integer, nil] nil when the endpoint did not report a total
    def total_count
      response = @transport.get(
        @path,
        operation:      @operation,
        resource_class: @resource_class,
        query:          @query.merge(only_total_count: true)
      )
      # Not every search endpoint honours only_total_count; one that ignores it
      # answers with the usual array of records, which is a shape to read
      # differently rather than a reason to raise.
      if response.body.is_a?(Hash)
        total = response.body[:total_count]
        return total if total.is_a?(Integer)
      end

      # That array is still a page of the result, and it carries the size of
      # the whole one in the same header every index endpoint sets. Read here,
      # an endpoint that ignores the parameter costs the one request it just
      # spent; unread, the probe was thrown away and `count` walked every page
      # on top of it, so the answer cost 1 + N requests instead of N.
      response.reported_total
    end

    # Reduced rather than refused, unlike the size {#page} takes. The
    # asymmetry is deliberate: a batch size says how much to fetch at a time,
    # so a smaller one costs more requests and still walks to the same last
    # record, while {#page}'s size also decides which records the page holds,
    # and reducing that answers a different question than the one asked.
    #
    # It is also what lets one batch size be written against resources that
    # cap differently - the index endpoints allow 1000, tickets 100, a search
    # 200 - without the caller looking each of them up.
    def clamp_per_page(size)
      raise ArgumentError, 'per_page needs to be a positive integer' if !size.is_a?(Integer) || !size.positive?

      [size, @max_per_page].min
    end
  end
end
