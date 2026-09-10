# frozen_string_literal: true

require_relative '../associations'
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

        # Every association declared on this resource, including inherited
        # ones.
        #
        # @return [Hash{Symbol => Hash}]
        def associations
          ancestors
            .select { it.respond_to?(:declared_associations, true) }
            .reverse
            .inject({}) { |result, ancestor| result.merge(ancestor.send(:declared_associations)) }
        end

        # The class carrying this resource's association readers, reached
        # through {Base#related}.
        #
        # @api private
        # @return [Class]
        def related_class
          # A resource's proxy inherits its parent's readers, so Base's
          # created_by and updated_by reach every resource.
          @related_class ||= Class.new(superclass.respond_to?(:related_class) ? superclass.related_class : Associations::Proxy) # steep:ignore NoMethod
        end

        private

        def declared_associations = @declared_associations ||= {}

        # Declares that this resource points at a single other record, through
        # a foreign key on itself.
        #
        # The reader lands on {Base#related}, not on the record, because Zammad
        # already expands the association into a name under the plain
        # attribute: +ticket.customer+ is a login, +ticket.related.customer+ is
        # the User record.
        #
        # @param name [Symbol] name of the reader on {Base#related}
        # @param class_name [String] the target resource, named rather than
        #   referenced so that two resources may point at each other
        # @param foreign_key [Symbol] attribute holding the target's id
        # @return [void]
        def belongs_to(name, class_name:, foreign_key: :"#{name}_id")
          declared_associations[name] = { type: :belongs_to, class_name: class_name, foreign_key: foreign_key }
          # The block runs against a Proxy instance, which the type checker
          # cannot see through define_method.
          related_class.define_method(name) { belongs_to_target(name, class_name, foreign_key) } # steep:ignore NoMethod
        end

        # Declares that this resource points at a list of other records,
        # served by an endpoint of its own.
        #
        # @param name [Symbol] name of the reader on {Base#related}
        # @param class_name [String] the target resource
        # @param path [Proc] called with the record, returns the API path
        # @return [void]
        def has_many(name, class_name:, path:)
          declared_associations[name] = { type: :has_many, class_name: class_name, path: path }
          related_class.define_method(name) { has_many_target(name, class_name, path) } # steep:ignore NoMethod
        end
      end

      # Zammad stamps every object with the user that created and last
      # touched it.
      belongs_to :created_by, class_name: 'User'
      belongs_to :updated_by, class_name: 'User'

      # @param transport [Transport]
      # @param attributes [Hash, nil]
      def initialize(transport, attributes = {})
        @transport  = transport
        @attributes = frozen_attributes(attributes || {})
        @changes    = {}
        @new_record = true
        @error      = nil
        @related    = nil
      end

      # @return [Boolean] whether this record has not been stored yet
      def new_record? = @new_record

      # @return [Boolean] whether this record exists in Zammad
      def persisted? = !@new_record

      # @return [Boolean] whether there are unsaved changes
      def changed? = !@changes.empty?

      # The records this one points at, each fetched on demand.
      #
      # Zammad expands an association into a name under the plain attribute,
      # so +ticket.customer+ is already the customer's login. These readers
      # return the whole record instead, which costs a request.
      #
      # @example
      #   ticket.customer               # => "customer@example.com", already loaded
      #   ticket.related.customer.email # => the same, from the User record
      #   ticket.related.articles       # => [TicketArticle, ...]
      #
      # @return [Associations::Proxy]
      # @see .associations
      def related = @related ||= self.class.related_class.new(self)

      # Stages several attributes as changes, without saving.
      #
      # @example
      #   group.assign_attributes(name: 'Support 2', note: 'Renamed')
      #   group.changed? # => true
      #
      # @param attributes [Hash] attribute names and their new values
      # @return [self]
      def assign_attributes(attributes)
        attributes.each { |key, value| write_attribute(key.to_sym, value) }
        self
      end

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
        @related    = nil
        true
      end

      # Stages several attributes and saves in one call.
      #
      # @example
      #   ticket.update(state: 'closed', priority: '1 low')
      #
      # @param attributes [Hash] attribute names and their new values
      # @return [Boolean] whether the record was stored
      # @raise [ResponseError] for any failure other than a validation error
      # @see #save
      def update(attributes)
        assign_attributes(attributes)
        save
      end

      # Stages several attributes and saves in one call, raising on any
      # failure.
      #
      # @param attributes [Hash] attribute names and their new values
      # @return [true]
      # @raise [ResponseError] when Zammad rejected the request
      # @see #save!
      def update!(attributes)
        assign_attributes(attributes)
        save!
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
        @related    = nil
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
