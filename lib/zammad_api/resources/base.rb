# frozen_string_literal: true

require_relative '../associations'
require_relative '../attribute_access'
require_relative '../errors'
require_relative '../transport'

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
      # whose endpoint caps lower declare +max_per_page+.
      DEFAULT_MAX_PER_PAGE = 1000

      # Query parameters an index endpoint honours, beyond the paging
      # {Collection} owns.
      #
      # ApplicationController#model_index_render builds its query as
      # `reorder(order_sql).offset(...).limit(...)` - it sorts and pages and
      # drops every other parameter. There is no attribute filtering on an
      # index endpoint at all; that is what /search is for. Resources whose
      # controller hardcodes the order declare +index_query_keys+ with
      # nothing in it.
      DEFAULT_INDEX_QUERY_KEYS = %i[sort_by order_by].freeze

      # Staged changes as +attribute => [old_value, new_value]+.
      #
      # A copy, and frozen: writing to the change set a record hands out would
      # decide what the next +save+ sends.
      #
      # @return [Hash{Symbol => Array(Object, Object)}]
      def changes = @changes.dup.freeze

      # The validation failure from the most recent {#save}, so that a +false+
      # return value can be acted on. Cleared when the next save is attempted,
      # so it never describes anything but the most recent one.
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
        # Declared rather than assumed, and false unless a resource says
        # otherwise: an unrouted `.../search` answers 404, which arrives as a
        # NotFoundError from inside {ResourceProxy#find_by} - a method
        # documented to return nil when nothing matched. A resource that
        # forgets to declare this is refused at the call site instead, which
        # is a question about the resource rather than a wrong answer about a
        # record.
        #
        # @param value [Boolean]
        # @return [void]
        def searchable(value)
          @searchable = value
        end

        # Declares the largest page size this resource's index endpoint
        # serves.
        #
        # @param value [Integer]
        # @return [void]
        def max_per_page(value)
          @max_per_page = value
        end

        # Declares the query parameters this resource's index endpoint
        # honours, beyond the paging {Collection} owns.
        #
        # @param keys [Array<Symbol>]
        # @return [void]
        def index_query_keys(*keys)
          @index_query_keys = keys.flatten.freeze
        end

        # @return [String] the API path of this resource
        def resource_path
          declaration(:path) || raise(Error, "#{name} does not declare an API path")
        end

        # @return [Boolean] whether Zammad routes a +/search+ endpoint here
        def searchable? = declaration(:searchable) { false }

        # @return [Integer] the largest page size this endpoint serves
        def page_limit = declaration(:max_per_page) { DEFAULT_MAX_PER_PAGE }

        # @return [Array<Symbol>] the query parameters {Collection#where} may
        #   pass to this endpoint
        def filterable_keys = declaration(:index_query_keys) { DEFAULT_INDEX_QUERY_KEYS }

        # The API path of one record of this kind.
        #
        # The id is escaped rather than interpolated, so that one taken from a
        # request parameter cannot walk out of its segment into another
        # endpoint. Held here because {ResourceProxy} builds this path too,
        # from an id a caller handed it, and an escaping rule kept in two
        # places is one that gets changed in one of them.
        #
        # @api private
        # @param id [Integer, String]
        # @return [String]
        # @raise [ArgumentError] when the id cannot go into a path segment
        def member_path(id) = "#{resource_path}/#{Transport.escape_path_segment(id)}"

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

        # The attributes a +belongs_to+ reader resolves through, so that
        # writing one can drop the record it had already resolved to.
        #
        # @api private
        # @return [Array<Symbol>]
        def belongs_to_foreign_keys
          @belongs_to_foreign_keys ||= associations.filter_map { |_, spec| spec[:foreign_key] if spec[:type] == :belongs_to }
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

        # Reads a declaration from this class, or failing that from the
        # resource it inherits from.
        #
        # A plain class-level ivar is not inherited, so `class MyTicket <
        # Ticket; end` used to inherit all nine of Ticket's associations, its
        # page limit and its searchability, and lose only its API path -
        # `MyTicket.resource_path` raised "does not declare an API path" from
        # a class that plainly did. {.associations} and {.related_class} both
        # walk the ancestry deliberately; these read through the same way.
        #
        # `instance_variable_defined?` rather than a truth test, so that a
        # resource may declare a value that is false or nil and have it
        # override an inherited one.
        def declaration(name, &default)
          variable = :"@#{name}"
          return instance_variable_get(variable) if instance_variable_defined?(variable)
          return superclass.send(:declaration, name, &default) if superclass.respond_to?(:declaration, true)

          default&.call
        end

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
        # The path has to name an endpoint that serves the whole list in one
        # response, which is what the association endpoints Zammad routes do.
        # The reader spends one request and hands back an Array rather than a
        # walking {Collection}, and refuses a response that turns out to be
        # one page of several rather than returning a short list quietly.
        #
        # @param name [Symbol] name of the reader on {Base#related}
        # @param class_name [String] the target resource
        # @param path [Proc] called with the record id, already escaped for
        #   a path segment, and returns the API path
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
        # What #changes measures against: the attributes this record arrived
        # with, kept apart from the ones it currently holds. The two share the
        # one frozen Hash until the first write copies it.
        @baseline   = @attributes
        @changes    = {}
        @new_record = true
        @destroyed  = false
        @error      = nil
        @related    = nil
      end

      # @return [Boolean] whether this record has not been stored yet
      def new_record? = @new_record

      # Whether this record exists in Zammad.
      #
      # False both before the first save and after {#destroy}, so this is not
      # the inverse of {#new_record?}.
      #
      # @return [Boolean]
      def persisted? = !@new_record && !@destroyed

      # Whether {#destroy} removed this record from Zammad.
      #
      # The attributes stay readable, so a destroyed record can still be logged
      # or reported on; it just no longer stands for anything on the server.
      #
      # @return [Boolean]
      def destroyed? = @destroyed

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
      # @raise [Error] when the record was destroyed
      # @see .associations
      def related
        # Asked here rather than left to the request. `destroy` drops the memo,
        # and that was taken to be the whole of it - but this reader rebuilds
        # on the next call, so a destroyed record went on handing out a working
        # proxy and `related.articles` fetched the articles of a ticket that is
        # gone. Clearing a memo is not refusing a reader, and only the refusal
        # is worth asserting: the spec that covered this compared proxy
        # identity, so it passed throughout.
        raise_if_destroyed!('read related records from')
        @related ||= self.class.related_class.new(self)
      end

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
        raise_if_destroyed!('save')

        # Before the request, not after it. Only the success path and the
        # rescue in `save` used to clear this, so a save that raised anything
        # else left the previous attempt's ValidationError in place and a
        # caller reading #error to report the failure read the wrong cause.
        @error = nil

        if !new_record?
          # An existing record is addressed by its id, so establish there is
          # one before anything here can report success. Only a record left
          # behind by a 2xx that did not decode reaches this without one, and
          # for that record the short circuit below is a lie: nothing is
          # staged, so `save` answered true without sending a request.
          require_id!

          # An unchanged record has nothing to send. The empty PUT this used
          # to issue was not just a wasted round trip: Zammad applies it,
          # bumping updated_at and updated_by, so re-saving a record that
          # nobody touched rewrote its audit trail and moved the timestamp
          # that other callers use to tell whether it changed under them.
          return true if !changed?
        end

        response = new_record? ? create_record : update_record

        replace_attributes!(response, operation: 'save object')
        true
      end

      # Stages several attributes and saves in one call.
      #
      # @example
      #   ticket.update(state: 'closed', priority: '1 low')
      #
      # @param attributes [Hash] attribute names and their new values
      # @return [Boolean] whether the record was stored
      # @raise [Error] when the record was destroyed
      # @raise [ResponseError] for any failure other than a validation error
      # @see #save
      def update(attributes)
        # Before the attributes are staged, not after. `save!` asks the same
        # question one line later, but by then `assign_attributes` has already
        # written into @changes, so `update` on a destroyed record raised and
        # left it dirty with a change set that can never be sent - exactly the
        # state `destroy` clears the staged changes to prevent.
        raise_if_destroyed!('save')
        assign_attributes(attributes)
        save
      end

      # Stages several attributes and saves in one call, raising on any
      # failure.
      #
      # @param attributes [Hash] attribute names and their new values
      # @return [true]
      # @raise [Error] when the record was destroyed
      # @raise [ResponseError] when Zammad rejected the request
      # @see #save!
      def update!(attributes)
        raise_if_destroyed!('save')
        assign_attributes(attributes)
        save!
      end

      # Re-reads the record from Zammad, discarding unsaved changes.
      #
      # @return [self]
      # @raise [Error] when the record was destroyed
      # @raise [ResponseError] when Zammad rejected the request
      # @raise [ParseError] when the response is not a JSON object
      def reload
        raise_if_destroyed!('reload')

        response = transport.get(
          member_path,
          operation:      'reload object',
          resource_class: self.class,
          query:          { expand: true }
        )
        replace_attributes!(response, operation: 'reload object')
        self
      end

      # Deletes the record.
      #
      # The record is marked {#destroyed?} rather than left looking live, so
      # that a later {#save}, {#reload} or second {#destroy} fails here with
      # the reason rather than one call later as a 404 from Zammad. The
      # attributes stay readable, but the state that only meant something
      # while the record existed does not: staged changes, the last validation
      # failure, and the association readers all go.
      #
      # @return [true]
      # @raise [Error] when the record was already destroyed
      # @raise [ResponseError] when Zammad rejected the request
      def destroy
        raise_if_destroyed!('destroy')

        transport.delete(member_path, operation: 'destroy object', resource_class: self.class)
        @destroyed = true
        reset_pending_state!
        true
      end

      def inspect = "#<#{self.class.name} id=#{id.inspect} new_record=#{new_record?}#{' destroyed=true' if destroyed?} attributes=#{attributes.inspect}>"

      private

      def mark_persisted!
        @new_record = false
      end

      # Refuses an operation on a record Zammad no longer holds.
      #
      # `destroyed?` is sticky, and all three state-changing paths ask here.
      # Only `save!` used to: `reload` re-read a record that no longer exists
      # and cleared the flag on the way back, so a destroyed record came back
      # reporting itself as persisted and its next `save` issued a PUT against
      # the deleted path, while a second `destroy` surfaced Zammad's 404
      # instead of the local reason. A record that is gone is gone, and every
      # path that acts on the server says so here rather than one request
      # later.
      def raise_if_destroyed!(action)
        raise Error, "#{self.class.name} #{id} was destroyed, there is nothing to #{action}" if destroyed?
      end

      def writable_attributes? = true

      # Everything a freshly loaded record has to forget, in the one place that
      # every load path goes through. Held apart, `save!` and `reload` drifted
      # the moment a sixth field was added to only one of them, and nothing
      # would have caught a reloaded record still holding an association proxy
      # from before the reload.
      # The flag goes down before the body is decoded, because what makes a
      # record persisted is that Zammad answered 2xx, not that the answer
      # parsed. Decoded first, a create whose 201 carried something other than
      # a JSON object - an HTML error page from an intervening proxy - raised
      # ParseError with @new_record still true, so the ticket existed in
      # Zammad while the record here still looked unsaved and a retried `save`
      # POSTed a second one.
      #
      # What that leaves behind is a record which is persisted and carries no
      # id, and the rest of this class has to treat it as the unusable thing
      # it is: a record built by `new` has nothing staged, so without a word
      # from {#require_id!} the retried `save` would have taken the "nothing
      # to send" short circuit and reported true, having made no request at
      # all, for a record that may or may not be in Zammad.
      def replace_attributes!(response, operation:)
        @new_record = false
        @attributes = frozen_attributes(response.decoded(:object, operation: operation, resource_class: self.class))
        @baseline   = @attributes
        reset_pending_state!
      end

      # The part of that which is not about arriving with new attributes, but
      # about the record's state on the server having changed underneath what
      # is held here. `destroy` is the third path through this, and was the
      # one left out: a destroyed record went on reporting `changed?` and a
      # change set that can never be sent, and went on handing out a `related`
      # proxy that would happily request a record that no longer exists.
      def reset_pending_state!
        @changes = {}
        @error   = nil
        @related = nil
      end

      # The baseline is the value this record was loaded with, not the value
      # the previous assignment happened to leave behind. Writing twice must
      # still report the original, and writing a value back to the original
      # is not a change at all - but only where the record was loaded
      # carrying that attribute in the first place.
      #
      # That last part is why the baseline is held rather than read back out
      # of @attributes: an attribute the record does not carry - Zammad
      # reduces the object it serializes for a permission-scoped client -
      # compared nil against nil on the way in, staged nothing, and was still
      # merged into @attributes below. The write was dropped without a word,
      # no request was ever sent for it, and the record went on reporting a
      # key Zammad had never sent it, so #changes and #attributes disagreed.
      def write_attribute(key, value)
        staged = frozen_attributes(value)

        if @baseline.key?(key) && @baseline[key] == staged
          @changes.delete(key)
        else
          @changes[key] = [@baseline[key], staged].freeze
        end

        # Copy on write, because @attributes is frozen for the benefit of
        # every reader that hands it out.
        @attributes = @attributes.merge(key => staged).freeze
        # A resolved association is only correct for the id it was resolved
        # from. `replace_attributes!` drops the proxy on save and reload, but
        # the write that actually changes a foreign key did not, so
        # `ticket.customer_id = 9` left `ticket.related.customer` answering
        # with user 3 and no request to show for it. The whole proxy goes:
        # evicting one reader means reaching into its cache for a saving that
        # is one request at most.
        @related = nil if self.class.belongs_to_foreign_keys.include?(key)
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

      def member_path = self.class.member_path(require_id!)

      # This record's id, for the paths and bodies that cannot be built
      # without one.
      #
      # @return [Integer] the id
      # @raise [Error] when the record has none
      def require_id!
        # Read once into a local, so that the guard below narrows what is
        # handed on - `id` is an attribute reader, and the type checker cannot
        # tell that two calls to one answer the same thing.
        record_id = id
        raise Error, no_id_message if record_id.nil?

        record_id
      end

      # A record has no id in two quite different situations, and one message
      # for both sent people looking in the wrong place. Before the first save
      # there is simply nothing to address yet. After one there is - Zammad
      # answered 2xx, so the record is in Zammad - but the response carried no
      # id to address it by, which is what {#replace_attributes!} leaves
      # behind when a 2xx body does not decode as the object it claims to be.
      def no_id_message
        return "#{self.class.name} has no id, save it first" if new_record?

        "#{self.class.name} was saved, but the response carried no id to address it by, " \
          'so this record cannot act on the server. Look it up again to get one that can.'
      end
    end
  end
end
