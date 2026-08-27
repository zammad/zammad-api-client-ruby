# frozen_string_literal: true

require_relative '../attribute_access'
require_relative '../errors'

module ZammadAPI
  module Resources
    # Shared behaviour for every Zammad record.
    #
    # Attributes are read and written through +method_missing+, because Zammad
    # records can carry administrator-defined custom attributes:
    #
    #   group      = client.group.find(1)
    #   group.name             # read
    #   group.name = 'Support' # stage a change
    #   group.changed?         # => true
    #   group.save             # persist
    class Base
      include AttributeAccess

      # @return [Hash{Symbol => Array(Object, Object)}] staged changes as
      #   +attribute => [old_value, new_value]+
      attr_reader :changes

      # @api private
      attr_reader :transport

      class << self
        # Declares the API path of this resource, relative to the instance URL.
        #
        # @param value [String]
        # @return [void]
        def path(value)
          @path = value
        end

        # @return [String] the API path of this resource
        def resource_path
          @path || raise(Error, "#{name} does not declare an API path")
        end

        # Builds a record that is already stored in Zammad.
        #
        # @api private
        # @param transport [Transport]
        # @param attributes [Hash]
        # @return [Base]
        def from_response(transport, attributes)
          record = new(transport, attributes)
          record.send(:mark_persisted!)
          record
        end
      end

      # @param transport [Transport]
      # @param attributes [Hash, nil]
      def initialize(transport, attributes = {})
        @transport  = transport
        @attributes = deep_symbolize(attributes || {})
        @changes    = {}
        @new_record = true
      end

      # @return [Boolean] whether this record has not been stored yet
      def new_record? = @new_record

      # @return [Boolean] whether this record exists in Zammad
      def persisted? = !@new_record

      # @return [Boolean] whether there are unsaved changes
      def changed? = !changes.empty?

      # Creates or updates the record.
      #
      # New records are sent in full; existing records send only the attributes
      # that changed.
      #
      # @return [true]
      # @raise [ResponseError] when Zammad rejected the request
      def save
        response = new_record? ? create_record : update_record

        @attributes = response.decoded(:object, operation: 'save object', resource_class: self.class)
        @changes    = {}
        @new_record = false
        true
      end

      # Re-reads the record from Zammad, discarding unsaved changes.
      #
      # @return [self]
      def reload
        response = transport.get(
          member_path,
          operation:      'reload object',
          resource_class: self.class,
          query:          { expand: true }
        )
        @attributes = response.body
        @changes    = {}
        @new_record = false
        self
      end

      # Deletes the record.
      #
      # @return [true]
      # @raise [ResponseError] when Zammad rejected the request
      def destroy
        transport.delete(member_path, operation: 'destroy object', resource_class: self.class)
        true
      end

      def inspect = "#<#{self.class.name} id=#{id.inspect} new_record=#{new_record?} attributes=#{attributes.inspect}>"

      private

      def mark_persisted!
        @new_record = false
      end

      def write_attribute(key, value)
        @changes[key] = [@attributes[key], value]
        @attributes[key] = value
        value
      end

      def create_record
        transport.post(
          self.class.resource_path,
          operation:      'save object',
          resource_class: self.class,
          query:          { expand: true },
          body:           attributes
        )
      end

      def update_record
        transport.put(
          member_path,
          operation:      'save object',
          resource_class: self.class,
          query:          { expand: true },
          body:           changes.transform_values { it[1] }
        )
      end

      def member_path
        raise Error, "#{self.class.name} has no id, save it first" if id.nil?

        "#{self.class.resource_path}/#{id}"
      end
    end
  end
end
