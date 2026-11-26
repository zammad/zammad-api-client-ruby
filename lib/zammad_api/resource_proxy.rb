# frozen_string_literal: true

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
    # This raises when Zammad rejects the attributes. Use +new+ and
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
      response = @transport.get(resource_class.member_path(id), operation: 'find object', resource_class: resource_class, query: { expand: true })

      resource_class.from_response(@transport, response.decoded(:object, operation: 'find object', resource_class: resource_class))
    end

    # The first record carrying all of these attribute values, or nil.
    #
    # An +id:+ is read with {#find}, in one request. Otherwise, where the
    # resource can be searched, the longest String value is the
    # search term and the hits are checked against every value. Otherwise
    # the index is walked until a record matches. Values are compared
    # exactly, and a record that does not carry an attribute does not match it.
    #
    # @example
    #   client.users.find_by(email: 'someone@example.com')
    #   client.ticket_states.find_by(name: 'open')
    #
    # @param params [Hash{Symbol => Object}]
    # @return [Resources::Base, nil]
    # @raise [ArgumentError] when no attribute was given
    def find_by(**params)
      raise ArgumentError, 'find_by needs at least one attribute to match' if params.empty?
      return find_by_id(params) if params.key?(:id)

      term       = params.values.grep(String).reject { it.strip.empty? }.max_by(&:length)
      candidates = resource_class.searchable? && term ? search(term) : all

      candidates.detect { |record| params.all? { |key, value| record.key?(key) && record[key] == value } }
    end

    # Like {#find_by}, but raises when nothing matched.
    #
    # @param params [Hash{Symbol => Object}]
    # @return [Resources::Base]
    # @raise [NotFoundError] when no record matched
    def find_by!(**params)
      find_by(**params) || raise(
        NotFoundError.new(
          operation:      "find object by #{params.keys.join(' and ')}",
          resource_class: resource_class,
          detail:         'no record matched'
        )
      )
    end

    # @param id [Integer, String]
    # @return [Boolean] whether a record with that id exists and can be read
    def exists?(id)
      find(id)
      true
    rescue NotFoundError
      false
    end

    # Deletes a record by id, without reading it first.
    #
    # @param id [Integer, String]
    # @return [true]
    # @raise [NotFoundError] when no such record exists
    def destroy(id)
      @transport.delete(resource_class.member_path(id), operation: 'destroy object', resource_class: resource_class)
      true
    end

    # Every record of this kind, as a lazily paginated collection.
    #
    # @return [Collection]
    def all = Collection.new(@transport, resource_class)

    # @!group Collection shorthands, each forwarded to {#all}

    # A forward hands on a block or a count that may be nil, which is what picks
    # the overload on the collection, and Steep cannot follow that through.

    # (see Collection#order)
    def order(*attributes, **directions) = all.order(*attributes, **directions)

    # (see Collection#each)
    def each(&block) = all.each(&block) # steep:ignore BlockTypeMismatch

    # (see Collection#find_each)
    def find_each(batch_size: nil, &block) = all.find_each(batch_size: batch_size, &block) # steep:ignore BlockTypeMismatch

    # (see Collection#in_batches)
    def in_batches(of: nil, &block) = all.in_batches(of: of, &block) # steep:ignore BlockTypeMismatch

    # (see Collection#page)
    def page(number, per_page: nil) = all.page(number, per_page: per_page)

    # (see Collection#pluck)
    def pluck(*keys) = all.pluck(*keys)

    # (see Collection#count)
    def count(...) = all.count(...)

    # (see Collection#empty?)
    def empty? = all.empty?

    # (see Collection#first)
    def first(count = nil) = all.first(count) # steep:ignore ArgumentTypeMismatch

    # @!endgroup

    # Records matching a Zammad search term, as a lazily paginated collection.
    #
    # Keywords are passed to the search endpoint as they are, for what it
    # narrows by besides the term, such as +condition:+ and +ids:+, or
    # +role_ids:+ for users.
    #
    # @example
    #   client.tickets.search('state.name:open').first(10)
    #   client.users.search('smith', role_ids: [2])
    #
    # @param term [String] a Zammad search query; +'*'+ matches every record
    # @param filters [Hash{Symbol => Object}] further search parameters
    # @return [Collection]
    # @raise [Error] for a resource Zammad routes no search endpoint for
    # @raise [ArgumentError] for a blank term, which Zammad reads as no term
    #   and answers with every record
    def search(term, **filters)
      raise Error, "Zammad routes no search endpoint for #{resource_class.name}: look a record up with find_by, which walks the records instead" if !resource_class.searchable?
      raise ArgumentError, "search needs a non-empty query string. Search for '*' to ask for every record." if !term.is_a?(String) || term.strip.empty?

      Collection.new(@transport, resource_class, search: true, query: { query: term, **filters })
    end

    def inspect = "#<#{self.class.name} #{resource_class.name}>"

    private

    def find_by_id(params)
      record = find(params.fetch(:id))
      record if params.except(:id).all? { |key, value| record.key?(key) && record[key] == value }
    rescue NotFoundError
      nil
    end
  end
end
