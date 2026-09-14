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
  #   client.group.all.where(sort_by: 'name').first(5)
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

    # Query parameters Zammad's search endpoints honour, from the call
    # ApplicationController#model_search_render makes into Model.search. Unlike
    # an index endpoint a search does narrow, but through these parameters and
    # the term - never through an attribute name of its own.
    SEARCH_QUERY_KEYS = %i[condition ids role_ids group_ids permissions sort_by order_by].freeze

    # Said at the end of the error for a parameter an index endpoint ignores.
    INDEX_FILTER_HINT = 'Zammad filters by attribute value only through a search endpoint, so use find_by for one record or search for many.'

    # The same, for a resource Zammad serves no search endpoint for, where
    # find_by and search are not an answer either.
    UNSEARCHABLE_FILTER_HINT = 'Zammad filters by attribute value only through a search endpoint, and routes none for this resource, so walk the records and pick with detect.'

    # The same, for a search endpoint.
    SEARCH_FILTER_HINT = 'Put the value in the search term instead.'

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
        member_path(id),
        operation:      'find object',
        resource_class: resource_class,
        query:          { expand: true }
      )
      resource_class.from_response(
        @transport,
        response.decoded(:object, operation: 'find object', resource_class: resource_class)
      )
    end

    # Fetches the first record carrying all of these attribute values.
    #
    # This searches and then checks the hits itself, because Zammad's index
    # endpoints cannot filter: ApplicationController#model_index_render sorts
    # and pages and drops every other parameter, so the previous
    # implementation - a query parameter on the index - asked for
    # +email=someone@example.com+ and got back the whole user index, of which
    # it returned the first record. A lookup that answers with an unrelated
    # record is worse than one that answers with nothing.
    #
    # Values are compared exactly, and against the record as Zammad stores it:
    # +find_by(email: 'Someone@Example.com')+ does not match a login Zammad
    # downcased.
    #
    # The search term is built from the string values only. Zammad searches by
    # word, so a value of another type went out as the word it prints as:
    # +find_by(active: true)+ searched for "true" and matched records carrying
    # that word, which is essentially none of them, and then reported the miss
    # as nil. A call with nothing to search for says so instead. The other
    # values still have to match, so +find_by(email: ..., active: true)+
    # searches the email and then compares both.
    #
    # What the search can surface is Zammad's business. A value the instance
    # has not indexed, or cannot index, is a record this does not find, so
    # +find_by(...) || create(...)+ can still create a duplicate - exactly as
    # writing the search out by hand would.
    #
    # Only the first {SEARCH_MAX_PER_PAGE} hits are examined, so this costs one
    # request whether it matches or not. Walking every page instead made a miss
    # cost a request per page of hits - a term appearing in a few thousand
    # records billed forty requests to answer "no", on exactly the
    # +find_by(...) || create(...)+ path that runs for every new record. Search
    # hits come back by relevance, so a record carrying the value searched for
    # is at the top of them or not among them at all; to look further, page
    # through {#search} directly.
    #
    # @example
    #   client.user.find_by(email: 'someone@example.com')&.id
    #
    # @param params [Hash] attribute names and the values to match exactly
    # @return [Resources::Base, nil] nil when nothing matched
    # @raise [ArgumentError] when no attribute was given, or none of the
    #   values is a string the search can be run on
    def find_by(**params)
      searchable!
      raise ArgumentError, 'find_by needs at least one attribute to match' if params.empty?

      term = params.values.grep(String).reject { it.strip.empty? }.join(' ')
      raise ArgumentError, unsearchable_values_message(params) if term.empty?

      search(term)
        .page(1, of: SEARCH_MAX_PER_PAGE)
        .detect { |record| params.all? { |key, value| record[key] == value } }
    end

    # Fetches the first record carrying all of these attribute values, raising
    # when nothing matched.
    #
    # @param params [Hash] attribute names and the values to match exactly
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
      @transport.delete(member_path(id), operation: 'destroy object', resource_class: resource_class)
      true
    end

    # Every record of this kind, as a lazily paginated collection.
    #
    # @return [Collection]
    def all
      collection(path, 'get .all of object')
    end

    # Records narrowed by the query parameters this endpoint honours, as a
    # lazily paginated collection. Shorthand for +all.where(...)+.
    #
    # An index endpoint does not filter by attribute value - see
    # {Collection#where} - so this is for sorting, and {#find_by} or {#search}
    # are how a value narrows anything.
    #
    # @param params [Hash] query parameters the endpoint honours
    # @return [Collection]
    # @raise [ArgumentError] for a parameter the endpoint would ignore
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
    # @raise [Error] when Zammad routes no search endpoint for this resource
    def search(term)
      searchable!
      raise ArgumentError, 'search needs a non-empty query string' if !term.is_a?(String) || term.strip.empty?

      collection(
        "#{path}/search",
        'get .search of object',
        query:        { query: term },
        max_per_page: SEARCH_MAX_PER_PAGE,
        filterable:   SEARCH_QUERY_KEYS,
        filter_hint:  SEARCH_FILTER_HINT,
        countable:    true
      )
    end

    def inspect = "#<#{self.class.name} #{resource_class.name}>"

    private

    def collection(path, operation, query: {}, max_per_page: resource_class::MAX_PER_PAGE, filterable: resource_class::INDEX_QUERY_KEYS, filter_hint: index_filter_hint, countable: false)
      Collection.new(
        transport:      @transport,
        resource_class: resource_class,
        path:           path,
        operation:      operation,
        max_per_page:   max_per_page,
        filterable:     filterable,
        filter_hint:    filter_hint,
        countable:      countable,
        query:          { expand: true }.merge(query)
      )
    end

    # Zammad routes a search endpoint per model, not for every model: users,
    # organizations, tickets and groups have one, ticket states, ticket
    # priorities and ticket articles do not. Asking one of the latter for
    # `.../search` is a 404, and a 404 out of `find_by` reads as "no such
    # record" - so `find_by(...) || create(...)`, the shape
    # examples/onboard_customer.rb is built on, raised instead of creating.
    def searchable!
      return if resource_class::SEARCHABLE

      raise Error, "Zammad routes no search endpoint for #{resource_class.name}, so it cannot be searched by term or looked up with find_by: #{path}/search answers 404, which would arrive here as a NotFoundError about a record. Walk the records and pick one instead, with all.detect { ... }."
    end

    def index_filter_hint = resource_class::SEARCHABLE ? INDEX_FILTER_HINT : UNSEARCHABLE_FILTER_HINT

    def unsearchable_values_message(params)
      given = params.map { |key, value| "#{key}: #{value.inspect}" }.join(', ')

      "find_by has nothing to search for in #{given}. Zammad matches words, so a value of another type goes out as the word it prints as - find_by(active: true) looks for records containing \"true\". " \
        'Pass at least one string value to search on, and the rest are still matched exactly: find_by(email: \'someone@example.com\', active: true). ' \
        'For a list short enough to walk, all.detect { ... } needs no search index at all.'
    end

    def path = resource_class.resource_path

    def member_path(id) = resource_class.member_path(id)
  end
end
