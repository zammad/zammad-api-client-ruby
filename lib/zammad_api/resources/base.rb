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

      # Largest page size Zammad's generic index endpoints serve, from
      # ApplicationController#model_index_render via CanPaginate. Resources
      # whose endpoint caps lower override this.
      MAX_PER_PAGE = 1000

      # Staged changes as +attribute => [old_value, new_value]+.
      #
      # A copy, and frozen: writing to the change set a record hands out would
      # decide what the next +save+ sends.
      #
      # @return [Hash{Symbol => Array(Object, Object)}]
      def changes = @changes.dup.freeze

      # The validation failure from the most recent {#save}, so that a +false+
      # return value can be acted on. Cleared by a successful save.
      #
      # @return [ValidationError, nil]
      attr_reader :error

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
        @attributes = frozen_attributes(attributes || {})
        @changes    = {}
        @new_record = true
        @error      = nil
      end

      # @return [Boolean] whether this record has not been stored yet
      def new_record? = @new_record

      # @return [Boolean] whether this record exists in Zammad
      def persisted? = !@new_record

      # @return [Boolean] whether there are unsaved changes
      def changed? = !@changes.empty?

      # Creates or updates the record, reporting a validation failure as
      # +false+ rather than by raising.
      #
      # Only a rejection of the submitted attributes is caught, and it is left
      # in {#error}. A missing record, an expired token or an unreachable
      # instance still raises, because retrying or branching on those is not
      # the caller's business here.
      #
      # @example
      #   if group.save
      #     puts group.id
      #   else
      #     warn group.error.server_message
      #   end
      #
      # @return [Boolean] whether the record was stored
      # @raise [ResponseError] for any failure other than a validation error
      # @see #save!
      def save
        save!
      rescue ValidationError => e
        @error = e
        false
      end

      # Creates or updates the record, raising on any failure.
      #
      # New records are sent in full; existing records send only the attributes
      # that changed.
      #
      # @return [true]
      # @raise [ResponseError] when Zammad rejected the request
      # @see #save
      def save!
        response = new_record? ? create_record : update_record

        @attributes = frozen_attributes(response.decoded(:object, operation: 'save object', resource_class: self.class))
        @changes    = {}
        @new_record = false
        @error      = nil
        true
      end

      # Re-reads the record from Zammad, discarding unsaved changes.
      #
      # @return [self]
      # @raise [ResponseError] when Zammad rejected the request
      # @raise [ParseError] when the response is not a JSON object
      def reload
        response = transport.get(
          member_path,
          operation:      'reload object',
          resource_class: self.class,
          query:          { expand: true }
        )
        @attributes = frozen_attributes(response.decoded(:object, operation: 'reload object', resource_class: self.class))
        @changes    = {}
        @new_record = false
        @error      = nil
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

      # The baseline is the value this record was loaded with, not the value
      # the previous assignment happened to leave behind. Writing twice must
      # still report the original, and writing a value back to the original
      # is not a change at all.
      def write_attribute(key, value)
        staged   = frozen_attributes(value)
        original = @changes.key?(key) ? @changes[key].first : @attributes[key]

        if original == staged
          @changes.delete(key)
        else
          @changes[key] = [original, staged].freeze
        end

        # Copy on write, because @attributes is frozen for the benefit of
        # every reader that hands it out.
        @attributes = @attributes.merge(key => staged).freeze
        staged
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
          body:           @changes.transform_values { it[1] }
        )
      end

      def member_path
        raise Error, "#{self.class.name} has no id, save it first" if id.nil?

        "#{self.class.resource_path}/#{id}"
      end
    end
  end
end
