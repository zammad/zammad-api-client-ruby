# frozen_string_literal: true

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
  #   client.ticket.all.in_batches(of: 500) { |tickets| import(tickets) }
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
      reserved = params.keys & RESERVED_QUERY_KEYS
      raise ArgumentError, "#{reserved.join(', ')} cannot be passed to where: use page, in_batches or find_each for paging, pass a search term to search, and leave expand and only_total_count to the collection" if !reserved.empty?

      ignored = params.keys - @filterable
      raise ArgumentError, ignored_message(ignored) if !ignored.empty?

      with(query: @query.merge(params))
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
      loop do
        records = fetch(page, @per_page)

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
        current = records.map(&:attributes).hash
        raise PaginationError.build(operation: @operation, page: page, resource_class: @resource_class) if current == previous

        yield records if !records.empty?

        # A collection limited to a single page never advances.
        break if @page
        break if records.empty?

        # How big a page this endpoint actually serves, learned from the first
        # one rather than assumed. The requested size is clamped to a per-
        # resource MAX_PER_PAGE, and where that guess was higher than the
        # server's real cap - a lowered setting, a custom deployment, an
        # endpoint whose cap was never this generous - every page came back
        # short and the walk stopped on page one with a truncated result and
        # nothing to show for it.
        page_size = records.size if page_size.zero?
        break if records.size < page_size

        previous = current
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

    def fetch(page, per_page)
      response = @transport.get(
        @path,
        operation:      @operation,
        resource_class: @resource_class,
        query:          @query.merge(page: page, per_page: per_page)
      )
      records = response.decoded(:array, operation: @operation, resource_class: @resource_class)
      records.map { @resource_class.from_response(@transport, it) }
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
      # answers with the usual array of records, which is a shape to walk
      # rather than a reason to raise.
      return nil if !response.body.is_a?(Hash)

      total = response.body[:total_count]
      total.is_a?(Integer) ? total : nil
    end

    def clamp_per_page(size)
      raise ArgumentError, 'per_page needs to be a positive integer' if !size.is_a?(Integer) || !size.positive?

      [size, @max_per_page].min
    end
  end
end
