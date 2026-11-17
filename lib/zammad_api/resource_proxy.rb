# frozen_string_literal: true

require 'forwardable'

require_relative 'collection'
require_relative 'duplicate_keys'
require_relative 'errors'
require_relative 'transport'

module ZammadAPI
  # Entry point for working with one kind of Zammad record.
  #
  # Obtained from {Client}, e.g. +client.tickets+, and exposes the operations
  # that are not tied to an individual record.
  #
  # @example
  #   client.groups.find(1)
  #   client.groups.create(name: 'Support')
  #   client.groups.all.each { |group| puts group.name }
  #   client.groups.order(:name).first(5)
  #   client.groups.search('support').first
  #
  # A proxy is +Enumerable+ over {#all}, so the collection surface is reachable
  # without naming it:
  #
  # @example
  #   client.groups.each { |group| puts group.name }
  #   client.groups.first(5)
  #   client.groups.map(&:name)
  #   client.groups.find_each(batch_size: 500) { |group| archive(group) }
  #
  # {#find} takes an id and is not +Enumerable#find+; +detect+ is still the
  # block form.
  class ResourceProxy
    include Enumerable
    extend Forwardable

    # Largest page size Zammad's search endpoints serve, from
    # ApplicationController#model_search_render.
    SEARCH_MAX_PER_PAGE = 200

    # What Zammad's search endpoints narrow by besides the term, from the call
    # ApplicationController#model_search_render makes into Model.search. Unlike
    # an index endpoint a search does narrow, but through these parameters and
    # the term - never through an attribute name of its own.
    SEARCH_FILTER_KEYS = %i[condition ids role_ids group_ids permissions].freeze

    # Said at the end of the error for sorting an index endpoint that is
    # always served in id order, on a resource that can be searched.
    SEARCHABLE_UNSORTABLE_HINT = 'A search does sort: search(term).order(...). Or sort what this collection yields, with sort_by { ... }.'

    # The same, for a resource Zammad routes no search endpoint for.
    UNSORTABLE_HINT = 'Sort what this collection yields instead, with sort_by { ... }.'

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
    def find(id) = resource_class.fetch_one(@transport, id)

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
    # The search term is one string value. Zammad searches by word, so a value
    # of another type went out as the word it prints as: +find_by(active:
    # true)+ searched for "true" and matched records carrying that word, which
    # is essentially none of them, and then reported the miss as nil. A call
    # with nothing to search for says so instead.
    #
    # One value, never all of them joined. An instance searching without
    # Elasticsearch matches the term literally, through a SQL LIKE over the
    # string columns, so a joined term asks every column to contain the whole
    # of it: +find_by(firstname: 'Jane', lastname: 'Doe')+ went out as "Jane
    # Doe" and no column of Jane Doe's holds that, so a user that exists came
    # back as nil and the +find_by(...) || create(...)+ this documents made a
    # duplicate on every run. Single-attribute lookups were unaffected, which
    # is why it stood. The longest value goes out, as the most selective of
    # them, and every other value is compared here - which is where the
    # non-string ones are compared anyway, so +find_by(email: ..., active:
    # true)+ searches the email and then checks both.
    #
    # Values go out as they are. Quoting one that carries search syntax, so
    # that it is looked for rather than obeyed, sounds like an improvement and
    # is not: an instance searching without Elasticsearch matches the term
    # literally, through a SQL LIKE over the string columns, so the quotes
    # become characters the value has to contain. That made
    # +find_by(name: 'support-eu')+ - a hyphen is syntax - find nothing on
    # every such instance, which is how this was found.
    #
    # So a value carrying syntax is searched as syntax, and what that surfaces
    # depends on the backend. On Elasticsearch +find_by(note: 'a AND b')+ goes
    # out as a boolean query, and a value Elasticsearch cannot parse at all -
    # an unbalanced +(+ or +"+ - takes SearchIndexBackend#search_by_index down
    # the branch that logs the error and returns no hits, so it arrives here
    # as a miss rather than as a failure.
    #
    # What the search can surface is Zammad's business. A value the instance
    # has not indexed, or cannot index, is a record this does not find, so
    # +find_by(...) || create(...)+ can still create a duplicate - exactly as
    # writing the search out by hand would.
    #
    # Every page of hits is read until one matches. Only the first
    # {SEARCH_MAX_PER_PAGE} used to be, to keep a miss at one request, on the
    # premise that hits come back by relevance and an exact match is at the
    # top of them or nowhere. They do not: Zammad's search endpoints sort by
    # +updated_at+, newest first, unless told otherwise, on the SQL path and
    # the Elasticsearch one alike. So where more than a page of records
    # matched the term - +find_by(name: 'Support')+ among a few hundred
    # organizations with "Support" in their name - the one called exactly
    # that could sit on any page, +find_by+ answered +nil+ for a record that
    # exists, and +find_by(...) || create(...)+ created its duplicate.
    #
    # So a match costs as many requests as it takes to reach it, and a miss
    # costs one per page of hits. The longest value is searched to keep
    # those few.
    #
    # @example
    #   client.users.find_by(email: 'someone@example.com')&.id
    #
    # @param params [Hash] attribute names and the values to match exactly
    # @return [Resources::Base, nil] nil when nothing matched
    # @raise [ArgumentError] when no attribute was given, or none of the
    #   values is a string the search can be run on
    def find_by(**params)
      searchable!
      raise ArgumentError, 'find_by needs at least one attribute to match' if params.empty?

      term = search_term_for(params)
      raise ArgumentError, unsearchable_values_message(params) if term.nil?

      search(term).detect { |record| params.all? { |key, value| record[key] == value } }
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

    # @!group Collection shorthands

    # Everything below forwards to {#all}, the {Collection} that decides for
    # itself what a missing block means and what a page size is measured
    # against.
    #
    # Named once rather than written out one +def+ at a time. Each was a body
    # that did nothing but pass its arguments on, and three carried a
    # +steep:ignore+ because forwarding into {Collection}'s with-block and
    # without-block overloads cannot be resolved - forwarded by name there is
    # no call site left to resolve. What callers are checked against is
    # sig/zammad_api/resource_proxy.rbs, where each of these is declared with
    # the types {Collection} gives it.

    # @!method order(*attributes, **directions)
    #   Every record of this kind, sorted by the server. Shorthand for
    #   +all.order(...)+.
    #   @example
    #     client.groups.order(:name)
    #     client.organizations.order(name: :desc)
    #   @param attributes [Array<Symbol, String>] attributes to sort by,
    #     ascending
    #   @param directions [Hash{Symbol => Symbol, String}] attributes to sort
    #     by, each with +:asc+ or +:desc+
    #   @return [Collection]
    #   @raise [ArgumentError] for a resource whose index endpoint does not
    #     sort
    #   @see Collection#order

    # @!method each(&block)
    #   Yields every record of this kind, fetching pages as needed.
    #
    #   This is what makes a proxy +Enumerable+, so +first+, +map+, +lazy+
    #   and the rest work straight off +client.groups+.
    #   @yieldparam record [Resources::Base]
    #   @return [Enumerator] when no block is given
    #   @see Collection#each

    # @!method find_each(batch_size: nil, &block)
    #   @param batch_size [Integer, nil] records fetched per request
    #   @yieldparam record [Resources::Base]
    #   @return [Enumerator] when no block is given
    #   @see Collection#find_each

    # @!method in_batches(of: nil, &block)
    #   @param of [Integer, nil] records fetched per request
    #   @yieldparam records [Array<Resources::Base>]
    #   @return [Enumerator] when no block is given
    #   @see Collection#in_batches

    # @!method page(number, per_page: nil)
    #   @param number [Integer] one-based page number
    #   @param per_page [Integer, nil] records on the page, as many as the
    #     endpoint serves by default
    #   @return [Collection]
    #   @see Collection#page

    # @!method pluck(*keys)
    #   @param keys [Array<Symbol, String>] attribute names
    #   @return [Array]
    #   @see Collection#pluck

    # @!method count(*args, &block)
    #   Overrides +Enumerable#count+ so that a collection counts the way it
    #   knows how.
    #   @return [Integer]
    #   @see Collection#count

    # @!method size
    #   @return [Integer]
    #   @see Collection#size

    # @!method length
    #   @return [Integer]
    #   @see Collection#size

    # @!method empty?
    #   @return [Boolean]
    #   @see Collection#empty?

    # @!method first(count = nil)
    #   Overrides +Enumerable#first+ so that it reads one sized page rather
    #   than taking records off the front of one sized for walking.
    #   @param count [Integer, nil] how many records to read
    #   @return [Resources::Base, Array<Resources::Base>, nil]
    #   @see Collection#first

    # @!method take(count)
    #   @param count [Integer] how many records to read
    #   @return [Array<Resources::Base>]
    #   @see Collection#take

    def_delegators :all, :order, :each, :find_each, :in_batches, :page, :pluck, :count, :size, :length, :empty?, :first, :take

    # @!endgroup

    # Records matching a Zammad search term, as a lazily paginated collection.
    #
    # The keywords are the other things a search endpoint narrows by. They
    # are named here, on the call that searches, because they mean nothing
    # anywhere else: they used to be passed to +where+ on the collection this
    # returns, the one place that method accepted more than a sort.
    #
    # Anything else is refused rather than sent. Zammad drops a parameter it
    # does not know, so +search('smith', active: true)+ would come back
    # unnarrowed and nothing would say so. An attribute value belongs in the
    # term, and a sort in {Collection#order}.
    #
    # @example
    #   client.users.search('smith')
    #   client.users.search('smith', role_ids: [2])
    #   client.tickets.search('printer', condition: {'ticket.state_id' => {operator: 'is', value: [1, 2]}})
    #   client.tickets.search('state.name:open').order(created_at: :desc)
    #
    # @param term [String] the Zammad search term
    # @param filters [Hash] any of +condition:+, +ids:+, +role_ids:+,
    #   +group_ids:+ and +permissions:+
    # @return [Collection]
    # @raise [ArgumentError] when +term+ is not a non-empty string, or for a
    #   keyword the search endpoint does not read, a nil value, or two
    #   spellings of one key
    # @raise [Error] when Zammad routes no search endpoint for this resource
    def search(term, **filters)
      searchable!
      raise ArgumentError, 'search needs a non-empty query string' if !term.is_a?(String) || term.strip.empty?

      collection(
        "#{path}/search",
        'get .search of object',
        query:        { query: term }.merge(search_filters(filters)),
        max_per_page: SEARCH_MAX_PER_PAGE,
        sortable:     true,
        countable:    true
      )
    end

    def inspect = "#<#{self.class.name} #{resource_class.name}>"

    private

    def collection(path, operation, query: {}, max_per_page: resource_class.page_limit, sortable: resource_class.sortable?, countable: false)
      Collection.new(
        transport:       @transport,
        resource_class:  resource_class,
        path:            path,
        operation:       operation,
        max_per_page:    max_per_page,
        sortable:        sortable,
        unsortable_hint: resource_class.searchable? ? SEARCHABLE_UNSORTABLE_HINT : UNSORTABLE_HINT,
        countable:       countable,
        query:           { expand: true }.merge(query)
      )
    end

    # The keywords of a search, checked at the call that wrote them.
    #
    # Through {Transport.stringify_query} for the two refusals it makes at
    # any depth - a nil value, and two spellings of one key inside a
    # +condition+ - because left to the request they would be reported when
    # the collection is first enumerated, some lines away from the search
    # that wrote them. What it returns is discarded: the collection sends the
    # values as they were given, and the transport stringifies them then.
    #
    # @return [Hash{Symbol => Object}]
    # @raise [ArgumentError]
    def search_filters(filters)
      normalized = DuplicateKeys.normalize(filters) { it.to_s.to_sym }
      unknown    = normalized.keys - SEARCH_FILTER_KEYS
      raise ArgumentError, unknown_search_filter_message(unknown) if !unknown.empty?

      Transport.stringify_query(normalized)
      normalized
    end

    def unknown_search_filter_message(unknown)
      "search does not take #{unknown.join(', ')}: a search endpoint narrows by the term, and by #{SEARCH_FILTER_KEYS.join(', ')}, and drops " \
        'anything else, which would hand back an unnarrowed search. ' \
        "Put an attribute value in the term - search('state.name:open') - sort with search(term).order(...), " \
        'and page with page, in_batches or find_each.'
    end

    # Zammad routes a search endpoint per model, not for every model: users,
    # organizations, tickets and groups have one, ticket states, ticket
    # priorities and ticket articles do not. Asking one of the latter for
    # `.../search` is a 404, and a 404 out of `find_by` reads as "no such
    # record" - so `find_by(...) || create(...)`, the shape
    # examples/onboard_customer.rb is built on, raised instead of creating.
    def searchable!
      return if resource_class.searchable?

      raise Error, "Zammad routes no search endpoint for #{resource_class.name}, so it cannot be searched by term or looked up with find_by: #{path}/search answers 404, which would arrive here as a NotFoundError about a record. Walk the records and pick one instead, with all.detect { ... }."
    end

    # The one value {#find_by} searches on: the longest, as the most selective
    # of them, which matters because a miss reads every page of hits.
    #
    # One value rather than all of them joined, and unquoted - both spellings
    # find nothing on an instance without Elasticsearch, for the same reason.
    # See {#find_by}.
    #
    # @return [String, nil] nil when no value can be searched on
    def search_term_for(params) = params.values.grep(String).reject { it.strip.empty? }.max_by(&:length)

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
