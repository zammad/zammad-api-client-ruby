# frozen_string_literal: true

require_relative 'collection'
require_relative 'errors'

module ZammadAPI
  # Entry point for working with one kind of Zammad record.
  #
  # Obtained from {Client}, e.g. +client.ticket+, and exposes the operations
  # that are not tied to an individual record.
  #
  # @example
  #   client.group.find(1)
  #   client.group.create(name: 'Support')
  #   client.group.all.each { |group| puts group.name }
  #   client.group.where(active: true).first(5)
  #   client.group.search('support').first
  #
  # A proxy is +Enumerable+ over {#all}, so the collection surface is reachable
  # without naming it:
  #
  # @example
  #   client.group.each { |group| puts group.name }
  #   client.group.first(5)
  #   client.group.map(&:name)
  #   client.group.find_each(batch_size: 500) { |group| archive(group) }
  #
  # {#find} takes an id and is not +Enumerable#find+; +detect+ is still the
  # block form.
  class ResourceProxy
    include Enumerable

    # Largest page size Zammad's search endpoints serve, from
    # ApplicationController#model_search_render.
    SEARCH_MAX_PER_PAGE = 200

    # @return [Class] the resource class this proxy operates on
    attr_reader :resource_class

    # @api private
    def initialize(transport, resource_class)
      @transport      = transport
      @resource_class = resource_class
    end

    # Builds an unsaved record.
    #
    # @param attributes [Hash]
    # @return [Resources::Base]
    def new(attributes = {})
      resource_class.new(@transport, attributes)
    end

    # Builds and immediately saves a record.
    #
    # This raises when Zammad rejects the attributes, rather than handing back
    # a record that looks created but is not. Use +new+ and
    # {Resources::Base#save} to branch on a validation failure instead.
    #
    # @param attributes [Hash]
    # @return [Resources::Base]
    # @raise [ResponseError] when Zammad rejected the request
    def create(attributes = {})
      record = new(attributes)
      record.save!
      record
    end

    # Fetches a single record by id.
    #
    # @param id [Integer, String]
    # @return [Resources::Base]
    # @raise [NotFoundError] when no such record exists
    def find(id)
      response = @transport.get(
        "#{path}/#{id}",
        operation:      'find object',
        resource_class: resource_class,
        query:          { expand: true }
      )
      resource_class.from_response(
        @transport,
        response.decoded(:object, operation: 'find object', resource_class: resource_class)
      )
    end

    # Fetches the first record matching Zammad query parameters.
    #
    # Only one record is requested, not a whole page.
    #
    # @example
    #   client.user.find_by(email: 'someone@example.com')&.id
    #
    # @param params [Hash] Zammad query parameters
    # @return [Resources::Base, nil] nil when nothing matched
    def find_by(**params) = where(**params).page(1, of: 1).first

    # Fetches the first record matching Zammad query parameters, raising when
    # nothing matched.
    #
    # @param params [Hash] Zammad query parameters
    # @return [Resources::Base]
    # @raise [NotFoundError] when nothing matched
    # @see #find_by
    def find_by!(**params)
      find_by(**params) || raise(
        NotFoundError.new(
          operation:      "find object by #{params.keys.join(' and ')}",
          resource_class: resource_class,
          detail:         'no record matched'
        )
      )
    end

    # Whether a record with this id exists.
    #
    # This costs one request, and reads the record to find out, because Zammad
    # has no cheaper answer for a single id.
    #
    # @param id [Integer, String]
    # @return [Boolean]
    def exists?(id)
      find(id)
      true
    rescue NotFoundError
      false
    end

    # Deletes a record by id, without fetching it first.
    #
    # @param id [Integer, String]
    # @return [true]
    # @raise [ResponseError] when Zammad rejected the request
    def destroy(id)
      @transport.delete("#{path}/#{id}", operation: 'destroy object', resource_class: resource_class)
      true
    end

    # Every record of this kind, as a lazily paginated collection.
    #
    # @return [Collection]
    def all
      collection(path, 'get .all of object')
    end

    # Records matching Zammad query parameters, as a lazily paginated
    # collection. Shorthand for +all.where(...)+.
    #
    # @param params [Hash] Zammad query parameters, e.g. +active:+
    # @return [Collection]
    def where(**params) = all.where(**params)

    # @!group Collection shorthands

    # Each of these forwards to {Collection}, which decides for itself what a
    # missing block means. The type checker cannot pick between the with-block
    # and without-block signatures while forwarding one that may be nil, hence
    # the annotations.

    # Yields every record of this kind, fetching pages as needed.
    #
    # This is what makes a proxy +Enumerable+, so +first+, +map+, +lazy+ and
    # the rest work straight off +client.group+.
    #
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    # @see Collection#each
    def each(&block) = all.each(&block) # steep:ignore BlockTypeMismatch

    # @param batch_size [Integer, nil] records fetched per request
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    # @see Collection#find_each
    def find_each(batch_size: nil, &block) = all.find_each(batch_size: batch_size, &block) # steep:ignore BlockTypeMismatch

    # @param of [Integer, nil] records fetched per request
    # @yieldparam records [Array<Resources::Base>]
    # @return [Enumerator] when no block is given
    # @see Collection#in_batches
    def in_batches(of: nil, &block) = all.in_batches(of: of, &block) # steep:ignore BlockTypeMismatch

    # @param number [Integer] one-based page number
    # @param of [Integer, nil] records on the page
    # @return [Collection]
    # @see Collection#page
    def page(number, of: nil) = all.page(number, of: of)

    # @param keys [Array<Symbol, String>] attribute names
    # @return [Array]
    # @see Collection#pluck
    def pluck(*keys) = all.pluck(*keys)

    # Overrides +Enumerable#count+ so that a collection counts the way it
    # knows how.
    #
    # @return [Integer]
    # @see Collection#count
    def count(*args, &block) = all.count(*args, &block)

    # @return [Integer]
    # @see Collection#size
    def size = all.size

    # @return [Integer]
    # @see Collection#size
    def length = all.length

    # @return [Boolean]
    # @see Collection#empty?
    def empty? = all.empty?

    # @!endgroup

    # Records matching a Zammad search term, as a lazily paginated collection.
    #
    # @param term [String] the Zammad search term
    # @return [Collection]
    # @raise [ArgumentError] when +term+ is not a non-empty string
    def search(term)
      raise ArgumentError, 'search needs a non-empty query string' if !term.is_a?(String) || term.strip.empty?

      collection(
        "#{path}/search",
        'get .search of object',
        query:        { query: term },
        max_per_page: SEARCH_MAX_PER_PAGE,
        countable:    true
      )
    end

    def inspect = "#<#{self.class.name} #{resource_class.name}>"

    private

    def collection(path, operation, query: {}, max_per_page: resource_class::MAX_PER_PAGE, countable: false)
      Collection.new(
        transport:      @transport,
        resource_class: resource_class,
        path:           path,
        operation:      operation,
        max_per_page:   max_per_page,
        countable:      countable,
        query:          { expand: true }.merge(query)
      )
    end

    def path = resource_class.resource_path
  end
end
