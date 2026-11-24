# frozen_string_literal: true

require_relative '../associations'
require_relative '../attribute_access'
require_relative '../deep_copy'
require_relative '../errors'
require_relative '../transport'

module ZammadAPI
  module Resources
    # Shared behaviour for every Zammad record.
    #
    # Attributes are read and written through +method_missing+, because Zammad
    # records can carry administrator-defined custom attributes:
    #
    #   group      = client.groups.find(1)
    #   group.name             # read
    #   group.name = 'Support' # stage a change
    #   group.changed?         # => true
    #   group.save             # persist
    class Base
      include AttributeAccess

      # Largest page size Zammad's generic index endpoints serve. Resources
      # whose endpoint caps lower declare +max_per_page+.
      DEFAULT_MAX_PER_PAGE = 1000

      # The validation failure from the most recent {#save}, so that a +false+
      # return value can be acted on.
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

        # Declares that Zammad routes a +/search+ endpoint for this resource.
        #
        # @param value [Boolean]
        # @return [void]
        def searchable(value)
          @searchable = value
        end

        # Declares the largest page size this resource's index endpoint serves.
        #
        # @param value [Integer]
        # @return [void]
        def max_per_page(value)
          @max_per_page = value
        end

        # Declares whether this resource's index endpoint reads +sort_by+ and
        # +order_by+. One that does not is refused by {Collection#order}.
        #
        # @param value [Boolean]
        # @return [void]
        def sortable(value)
          @sortable = value
        end

        # Declares whether this resource's index endpoint pages. One that
        # serves every record in one response is read in one request.
        #
        # @example
        #   class ObjectAttribute < ZammadAPI::Resources::Base
        #     path 'api/v1/object_manager_attributes'
        #     paginated false
        #     sortable false
        #   end
        #
        # @param value [Boolean]
        # @return [void]
        def paginated(value)
          @paginated = value
        end

        # @return [String] the API path of this resource
        # @raise [Error] when the resource declares none
        def resource_path
          declaration(:path) || raise(Error, "#{name} does not declare an API path")
        end

        # @return [Boolean] whether Zammad routes a +/search+ endpoint here
        def searchable? = declaration(:searchable) { false }

        # @return [Integer] the largest page size this endpoint serves
        def page_limit = declaration(:max_per_page) { DEFAULT_MAX_PER_PAGE }

        # @return [Boolean] whether the index endpoint reads +sort_by+ and +order_by+
        def sortable? = declaration(:sortable) { true }

        # @return [Boolean] whether the index endpoint reads +page+ and +per_page+
        def paginated? = declaration(:paginated) { true }

        # The API path of one record of this kind, with the id escaped.
        #
        # @api private
        # @param id [Integer, String]
        # @return [String]
        def member_path(id) = "#{resource_path}/#{Transport.escape_path_segment(id)}"

        # Reads one record by id.
        #
        # @api private
        # @param transport [Transport]
        # @param id [Integer, String]
        # @return [Base]
        def fetch_one(transport, id)
          operation = 'find object'
          response  = transport.get(member_path(id), operation: operation, resource_class: self, query: { expand: true })

          from_response(transport, response.decoded(:object, operation: operation, resource_class: self))
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

        # Every association this resource declares, including inherited ones.
        #
        # @return [Hash{Symbol => Hash}]
        def associations
          inherited = superclass.respond_to?(:associations) ? superclass.associations : {} # steep:ignore NoMethod
          inherited.merge(declared_associations)
        end

        private

        # A declaration of this class, or failing that of the class it inherits from.
        def declaration(name, &default)
          variable = :"@#{name}"
          return instance_variable_get(variable) if instance_variable_defined?(variable)
          return superclass.send(:declaration, name, &default) if superclass.respond_to?(:declaration, true)

          default&.call
        end

        def declared_associations = @declared_associations ||= {}

        # Declares that this resource points at a single other record, through
        # a foreign key on itself. Read through +record.related.<name>+.
        #
        # @param name [Symbol] name of the reader on {Base#related}
        # @param class_name [String] the target resource: one of this gem by its
        #   own name, +'User'+, or another by its full name, +'Acme::Role'+
        # @param foreign_key [Symbol] attribute holding the target's id
        # @return [void]
        def belongs_to(name, class_name:, foreign_key: :"#{name}_id")
          declared_associations[name] = { type: :belongs_to, class_name: class_name, foreign_key: foreign_key }
        end

        # Declares that this resource points at a list of other records, served
        # whole by an endpoint of its own. Read through +record.related.<name>+.
        #
        # @param name [Symbol] name of the reader on {Base#related}
        # @param class_name [String] the target resource
        # @param path [Proc] called with the record id, already escaped for
        #   a path segment, and returns the API path
        # @return [void]
        def has_many(name, class_name:, path:)
          declared_associations[name] = { type: :has_many, class_name: class_name, path: path }
        end
      end

      # Zammad stamps every object with the user that created and last
      # touched it.
      belongs_to :created_by, class_name: 'User'
      belongs_to :updated_by, class_name: 'User'

      # @param transport [Transport]
      # @param attributes [Hash, nil] or what converts to a Hash, such as
      #   permitted `ActionController::Parameters`
      def initialize(transport, attributes = {})
        @transport  = transport
        @attributes = frozen_attributes(Hash(attributes)) # steep:ignore UnresolvedOverloading
        @baseline   = @attributes
        @new_record = true
        @destroyed  = false
        @error      = nil
        @related    = nil
      end

      # @api private
      # @param source [Base]
      # @return [void]
      def initialize_copy(source)
        super
        @related = nil
      end

      # @return [Boolean] whether this record has not been stored yet
      def new_record? = @new_record

      # Whether this record exists in Zammad: false both before the first save
      # and after {#destroy}.
      #
      # @return [Boolean]
      def persisted? = !@new_record && !@destroyed

      # @return [Boolean] whether {#destroy} removed this record from Zammad
      def destroyed? = @destroyed

      # Staged changes as +attribute => [old_value, new_value]+.
      #
      # @return [Hash{Symbol => Array(Object, Object)}]
      def changes
        @attributes.filter_map { |key, value| [key, [@baseline[key], value].freeze] if !@baseline.key?(key) || @baseline[key] != value }.to_h.freeze
      end

      # @return [Boolean] whether there are staged changes
      def changed? = !changes.empty?

      # The records this one points at.
      #
      # @example
      #   ticket.related.customer # => the User record, one request
      #
      # @return [Associations::Proxy]
      def related
        @related ||= Associations::Proxy.new(self)
      end

      # Stages several changes at once.
      #
      # @param attributes [Hash]
      # @return [self]
      def assign_attributes(attributes)
        Hash(attributes).each { |key, value| write_attribute(DeepCopy.symbolize(key), value) }
        self
      end

      # Persists this record, creating it if it is new.
      #
      # @return [Boolean] false when Zammad rejected the attributes; see {#error}
      # @raise [ResponseError] for any other failure
      def save
        save!
      rescue ValidationError => e
        @error = e
        false
      end

      # Persists this record, creating it if it is new. An existing record
      # sends only the attributes that changed, and nothing when none did.
      #
      # @return [true]
      # @raise [ValidationError] when Zammad rejected the attributes
      def save!
        @error = nil

        if new_record?
          response = transport.post(self.class.resource_path, operation: 'save object', resource_class: self.class, query: { expand: true }, body: @attributes)
        else
          unsaved = changes.transform_values(&:last)
          return true if unsaved.empty?

          response = transport.put(member_path, operation: 'save object', resource_class: self.class, query: { expand: true }, body: unsaved)
        end

        load_response!(response, 'save object')
        true
      end

      # Stages the attributes and saves.
      #
      # @param attributes [Hash]
      # @return [Boolean] see {#save}
      def update(attributes)
        assign_attributes(attributes)
        save
      end

      # Stages the attributes and saves.
      #
      # @param attributes [Hash]
      # @return [true]
      # @raise [ValidationError] see {#save!}
      def update!(attributes)
        assign_attributes(attributes)
        save!
      end

      # Reads this record again, dropping staged changes.
      #
      # @return [self]
      # @raise [Error] when the record is new
      def reload
        raise_if_new!('reload')

        response = transport.get(member_path, operation: 'reload object', resource_class: self.class, query: { expand: true })
        load_response!(response, 'reload object')
        self
      end

      # Deletes this record in Zammad.
      #
      # @return [true]
      # @raise [Error] when the record is new
      def destroy
        raise_if_new!('destroy')

        transport.delete(member_path, operation: 'destroy object', resource_class: self.class)
        @destroyed = true
        true
      end

      def inspect = "#<#{self.class.name} id=#{id.inspect} new_record=#{new_record?}#{' destroyed=true' if destroyed?} attributes=#{Transport.redact(attributes).inspect}>"

      private

      def mark_persisted!
        @new_record = false
      end

      def load_response!(response, operation)
        @attributes = frozen_attributes(response.decoded(:object, operation: operation, resource_class: self.class))
        @baseline   = @attributes
        @new_record = false
        @related&.forget
      end

      def raise_if_new!(operation)
        raise Error, "#{self.class.name} has not been saved, so there is nothing to #{operation}" if new_record?
      end

      def writable_attributes? = true

      def write_attribute(key, value)
        raise Error, "#{self.class.name}#id cannot be changed: it is what addresses this record" if key == :id

        staged      = frozen_attributes(value)
        @attributes = @attributes.merge(key => staged).freeze
        @related&.forget
        staged
      end

      def member_path = self.class.member_path(require_id!)

      def require_id!
        id || raise(Error, "#{self.class.name} has no id, save it first")
      end
    end
  end
end
