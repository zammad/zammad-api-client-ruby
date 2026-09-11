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
  # @example Filter, then stop after the first five matches
  #   client.ticket.where(state: 'open').first(5)
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
    RESERVED_QUERY_KEYS = %i[page per_page expand only_total_count].freeze
    private_constant :RESERVED_QUERY_KEYS

    # @api private
    def initialize(transport:, resource_class:, path:, operation:, max_per_page:, query: {}, per_page: DEFAULT_PER_PAGE, page: nil, countable: false)
      @transport      = transport
      @resource_class = resource_class
      @path           = path
      @operation      = operation
      @query          = query
      @max_per_page   = max_per_page
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
      return with(per_page: positive_integer!(batch_size, 'batch_size')).find_each(&block) if batch_size

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
      return with(per_page: positive_integer!(of, 'of')).in_batches(&block) if of

      walk(&block)
      self
    end

    # Returns a new collection limited to a single page.
    #
    # +of+ decides how big that page is, and so which records it holds:
    # +page(2, of: 50)+ is records 51 to 100. Zammad caps the page size per
    # endpoint, so a larger size is reduced to what the endpoint serves.
    #
    # @example
    #   client.ticket.all.page(2, of: 50).to_a
    #
    # @param number [Integer] one-based page number
    # @param of [Integer, nil] records on the page, {DEFAULT_PER_PAGE} by default
    # @return [Collection]
    def page(number, of: nil)
      raise ArgumentError, 'page needs to be a positive integer' if !number.is_a?(Integer) || !number.positive?

      with(page: number, per_page: of ? positive_integer!(of, 'of') : @per_page)
    end

    # Returns a new collection with additional query parameters applied.
    #
    # @param params [Hash] Zammad query parameters, e.g. +state:+ or +sort_by:+
    # @return [Collection]
    # @raise [ArgumentError] for a parameter this collection controls itself
    def where(**params)
      reserved = params.keys & RESERVED_QUERY_KEYS
      raise ArgumentError, "#{reserved.join(', ')} cannot be passed to where: use page, in_batches or find_each for paging, and leave expand and only_total_count to the collection" if !reserved.empty?

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
    #   client.ticket.where(state: 'merged').empty?
    #
    # @return [Boolean]
    def empty? = (@page ? self : page(1, of: 1)).first.nil?

    def inspect
      "#<#{self.class.name} #{@resource_class.name} path=#{@path.inspect} per_page=#{@per_page}#{" page=#{@page}" if @page}>"
    end

    private

    def positive_integer!(value, name)
      raise ArgumentError, "#{name} needs a positive integer" if !value.is_a?(Integer) || !value.positive?

      value
    end

    def walk
      page     = @page || 1
      previous = nil
      loop do
        records = fetch(page, @per_page)
        yield records if !records.empty?

        # A collection limited to a single page never advances.
        break if @page

        # A short page means the server has no more records. The page size is
        # clamped to what the endpoint serves, so it cannot be short because
        # the server shrank it.
        break if records.size < @per_page

        # Whole payloads rather than ids: an endpoint that serves records
        # without an id would compare two empty lists on every page and so
        # report a perfectly good paginator as stuck.
        current = records.map(&:attributes)
        raise PaginationError.build(operation: @operation, page: page, resource_class: @resource_class) if current == previous

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
