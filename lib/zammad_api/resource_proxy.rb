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
  class ResourceProxy
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
    # @param attributes [Hash]
    # @return [Resources::Base]
    # @raise [ResponseError] when Zammad rejected the request
    def create(attributes = {})
      record = new(attributes)
      record.save
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
