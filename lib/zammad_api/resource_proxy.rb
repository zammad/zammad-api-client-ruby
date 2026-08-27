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
  #   client.group.search(query: 'support').first
  class ResourceProxy
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
      body = response.body

      if !body.is_a?(Hash)
        raise ParseError, "Can't find object (#{resource_class.name}): expected a JSON object, got #{body.class}"
      end

      resource_class.from_response(@transport, body)
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

    # All records of this kind, paginated automatically.
    #
    # @param per_page [Integer] records fetched per request
    # @param query [Hash] additional query parameters
    # @return [Collection]
    def all(per_page: Collection::DEFAULT_PER_PAGE, **query)
      collection(path, 'get .all of object', per_page: per_page, query: query)
    end

    # Records matching a search term, paginated automatically.
    #
    # @param query [String] the Zammad search term
    # @param per_page [Integer] records fetched per request
    # @param params [Hash] additional query parameters
    # @return [Collection]
    def search(query:, per_page: Collection::DEFAULT_PER_PAGE, **params)
      collection(
        "#{path}/search",
        'get .search of object',
        per_page: per_page,
        query:    params.merge(query: query)
      )
    end

    def inspect
      "#<#{self.class.name} #{resource_class.name}>"
    end

    private

    def collection(path, operation, per_page:, query:)
      Collection.new(
        transport:      @transport,
        resource_class: resource_class,
        path:           path,
        operation:      operation,
        per_page:       per_page,
        query:          { expand: true }.merge(query)
      )
    end

    def path
      resource_class.resource_path
    end
  end
end
