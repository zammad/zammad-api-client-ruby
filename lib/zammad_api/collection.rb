# frozen_string_literal: true

require_relative 'errors'

module ZammadAPI
  # A lazily fetched, automatically paginated list of records.
  #
  # {#each} walks every page until the server runs out of records, so it is
  # safe to iterate a collection larger than one page. Combine it with
  # +Enumerable+ methods such as +first+, +lazy+ or +find+ to stop early
  # without downloading everything.
  #
  # @example Iterate every ticket
  #   client.ticket.all.each { |ticket| puts ticket.title }
  #
  # @example Stop after the first match without fetching all pages
  #   client.ticket.all.lazy.select { |t| t.state == 'open' }.first(5)
  #
  # @example Work page by page
  #   client.ticket.all.each_page { |tickets| import(tickets) }
  class Collection
    include Enumerable

    # Records fetched per request. Zammad caps this per endpoint.
    DEFAULT_PER_PAGE = 100

    # @return [Integer] number of records requested per page
    attr_reader :per_page

    # @return [Integer, nil] the single page this collection is limited to
    attr_reader :current_page

    # @api private
    def initialize(transport:, resource_class:, path:, operation:, query: {}, per_page: DEFAULT_PER_PAGE, page: nil)
      raise ArgumentError, 'per_page needs to be a positive integer' if !per_page.is_a?(Integer) || !per_page.positive?

      @transport      = transport
      @resource_class = resource_class
      @path           = path
      @operation      = operation
      @query          = query
      @per_page       = per_page
      @current_page   = page
    end

    # Yields every record, fetching further pages as needed.
    #
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    def each(&block)
      return to_enum(:each) if !block_given?

      each_page { |records| records.each(&block) }
      self
    end

    # Yields one array of records per page.
    #
    # @yieldparam records [Array<Resources::Base>]
    # @return [Enumerator] when no block is given
    def each_page
      return to_enum(:each_page) if !block_given?

      page = current_page || 1
      loop do
        records = fetch(page, per_page)
        yield records if !records.empty?

        # A short page means the server has no more records. A collection
        # limited to a single page never advances.
        break if current_page || records.size < per_page

        page += 1
      end
      self
    end

    # Returns a new collection limited to a single page.
    #
    # @param number [Integer] one-based page number
    # @param per_page [Integer, nil] defaults to this collection's page size
    # @return [Collection]
    def page(number, per_page: nil)
      raise ArgumentError, 'page needs to be a positive integer' if !number.is_a?(Integer) || !number.positive?

      with(page: number, per_page: per_page || self.per_page)
    end

    # Returns a new collection with additional query parameters applied.
    #
    # @param params [Hash]
    # @return [Collection]
    def where(**params)
      with(query: @query.merge(params))
    end

    # Fetches the record at +index+ across the whole result set.
    #
    # @param index [Integer] zero-based index
    # @return [Resources::Base, nil]
    def [](index)
      raise ArgumentError, 'index needs to be a non-negative integer' if !index.is_a?(Integer) || index.negative?

      fetch(index + 1, 1).first
    end

    def inspect
      "#<#{self.class.name} #{@resource_class.name} path=#{@path.inspect} per_page=#{per_page}#{" page=#{current_page}" if current_page}>"
    end

    private

    def with(page: current_page, per_page: self.per_page, query: @query)
      self.class.new(
        transport:      @transport,
        resource_class: @resource_class,
        path:           @path,
        operation:      @operation,
        query:          query,
        per_page:       per_page,
        page:           page
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
  end
end
