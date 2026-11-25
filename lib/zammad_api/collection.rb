# frozen_string_literal: true

require_relative 'errors'

module ZammadAPI
  # A lazily fetched, automatically paginated list of records.
  #
  # Nothing is requested until the collection is iterated. {#order} and
  # {#page} return new collections, so a collection can be built up in
  # steps and shared without being disturbed.
  #
  # {#each} walks every page until the server runs out of records, so it is
  # safe to iterate a collection larger than one page. {#first} reads one page
  # sized for what it was asked for, and +lazy+, +detect+ and the rest of
  # +Enumerable+ stop the walk as soon as they have enough.
  #
  # @example Iterate every ticket
  #   client.tickets.all.each { |ticket| puts ticket.title }
  #
  # @example Narrow to matches, then stop after the first five
  #   client.tickets.search('state.name:open').first(5)
  #
  # @example Sorted by the server
  #   client.groups.order(:name).each { |group| puts group.name }
  #
  # @example Work in batches, e.g. for an import
  #   client.tickets.all.in_batches(of: 50) { |tickets| import(tickets) }
  #
  # @example One explicit page
  #   client.tickets.all.page(2, per_page: 50).to_a
  class Collection
    include Enumerable

    # Largest page size Zammad's search endpoints serve.
    SEARCH_MAX_PER_PAGE = 200

    # @api private
    # @param per_page [Integer, nil] records fetched per request, or nil for
    #   as many as the endpoint serves
    # @param search [Boolean] whether this is a search endpoint, which can
    #   serve a short page before the last one, can count its results and
    #   always sorts
    def initialize(transport:, resource_class:, path:, operation:, query: {}, per_page: nil, page: nil, search: false)
      max_per_page = search ? SEARCH_MAX_PER_PAGE : resource_class.page_limit

      @transport      = transport
      @resource_class = resource_class
      @path           = path
      @operation      = operation
      @query          = query
      @per_page       = [per_page || max_per_page, max_per_page].min
      @page           = page
      @search         = search
    end

    # Yields every record, fetching pages as needed.
    #
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    def each(&block)
      return to_enum(:each) if !block

      in_batches { |records| records.each(&block) }
      self
    end

    # Yields every record, fetching +batch_size+ records per request.
    #
    # @param batch_size [Integer, nil]
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    def find_each(batch_size: nil, &block)
      return to_enum(:find_each, batch_size: batch_size) if !block
      return with(per_page: batch_size).find_each(&block) if batch_size

      each(&block)
    end

    # Yields one array of records per page.
    #
    # @param of [Integer, nil] records fetched per request
    # @yieldparam records [Array<Resources::Base>]
    # @return [Enumerator] when no block is given
    def in_batches(of: nil, &block)
      return to_enum(:in_batches, of: of) if !block
      return with(per_page: of).in_batches(&block) if of

      walk(&block)
      self
    end

    # Returns a new collection limited to a single page.
    #
    # @example
    #   client.tickets.all.page(2, per_page: 50).to_a
    #
    # @param number [Integer] one-based page number
    # @param per_page [Integer, nil] records on the page, at most what the
    #   endpoint serves
    # @return [Collection]
    def page(number, per_page: nil) = with(page: number, per_page: per_page || @per_page)

    # Returns a new collection sorted by the server.
    #
    # Attributes named on their own sort ascending, and a keyword says which
    # way one runs. A second +order+ sorts within the first.
    #
    # @example
    #   client.groups.order(:name).first(5)
    #   client.organizations.order(name: :desc)
    #
    # @param attributes [Array<Symbol, String>] attributes to sort by, ascending
    # @param directions [Hash{Symbol => Symbol, String}] attributes to sort by,
    #   each with +:asc+ or +:desc+
    # @return [Collection]
    # @raise [ArgumentError] for an endpoint that does not sort
    def order(*attributes, **directions)
      raise ArgumentError, "#{@path} is always served in the same order and ignores sort_by" if !@search && !@resource_class.sortable?

      requested = attributes.to_h { [it.to_s, 'asc'] }.merge(directions.to_h { |name, direction| [name.to_s, direction.to_s] })
      columns   = sorted_by.merge(requested)
      with(query: @query.merge(sort_by: columns.keys.join(','), order_by: columns.values.join(',')))
    end

    # Reads one or more attributes from every record.
    #
    # @example
    #   client.users.all.pluck(:email)          # => ["a@example.com", ...]
    #   client.tickets.all.pluck(:id, :title)   # => [[1, "Help"], ...]
    #
    # @param keys [Array<Symbol, String>] attribute names
    # @return [Array]
    def pluck(*keys)
      return map { it[keys.first] } if keys.one?

      map { |record| keys.map { record[it] } }
    end

    # The first record, or the first +count+ of them, read with a request sized
    # for what was asked rather than a whole page.
    #
    # @param count [Integer, nil]
    # @return [Resources::Base, Array<Resources::Base>, nil]
    def first(count = nil)
      source = @page ? self : with(per_page: count || 1)

      count.nil? ? source.each.first : source.each.first(count)
    end

    # +Enumerable#find+, which takes a block. Look a record up by id on the
    # resource instead: +client.tickets.find(1)+.
    #
    # @yieldparam record [Resources::Base]
    # @return [Resources::Base, nil]
    # @raise [ArgumentError] when given an id where a block belongs
    def find(*args, &block)
      raise ArgumentError, "find on a collection takes a block; look a record up by id with client.<resource>.find(#{args.first.inspect})" if block.nil? && !args.empty?

      super
    end

    # Number of records in this collection: one request on a search, which
    # Zammad can count without serving the records, and a walk otherwise.
    #
    # There is no +size+ or +length+: +each_slice+ and +each_cons+ ask for
    # the size before they start, and that would read every record twice.
    #
    # @return [Integer]
    def count(*args, &block)
      return super if !args.empty? || block || @page || !@search

      total_count || super
    end

    # @return [Boolean] whether the collection holds no records, read with
    #   one request for one record
    def empty? = first.nil?

    def inspect
      "#<#{self.class.name} #{@resource_class.name} path=#{@path.inspect} per_page=#{@per_page}#{" page=#{@page}" if @page}>"
    end

    private

    # Fetches page after page until one comes back empty. An index also stops
    # at a short page; a search can serve one before the last.
    #
    # Not `loop`, which would end the walk quietly on a StopIteration raised
    # by the caller's block; and the page is judged before the block gets it,
    # since the block may change the Array.
    def walk
      number   = @page || 1
      previous = nil
      last     = false

      until last
        records = fetch(number)
        break if records.empty?

        ids = records.map(&:id)
        raise PaginationError.build(operation: @operation, page: number, resource_class: @resource_class) if ids == previous

        last = !@page.nil? || (!@search && records.size < @per_page)
        yield records

        previous = ids
        number  += 1
      end
    end

    def fetch(number)
      response = @transport.get(@path, operation: @operation, resource_class: @resource_class, query: @query.merge(page: number, per_page: @per_page))

      response.decoded(:array, operation: @operation, resource_class: @resource_class).map { @resource_class.from_response(@transport, it) }
    end

    def total_count
      response = @transport.get(@path, operation: @operation, resource_class: @resource_class, query: @query.merge(only_total_count: true))
      total    = response.body.is_a?(Hash) ? response.body[:total_count] : nil
      total if total.is_a?(Integer)
    end

    def sorted_by
      @query.fetch(:sort_by, '').to_s.split(',').zip(@query.fetch(:order_by, '').to_s.split(',')).to_h
    end

    def with(page: @page, per_page: @per_page, query: @query)
      self.class.new(
        transport:      @transport,
        resource_class: @resource_class,
        path:           @path,
        operation:      @operation,
        query:          query,
        per_page:       per_page,
        page:           page,
        search:         @search
      )
    end
  end
end
