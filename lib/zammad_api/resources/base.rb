# frozen_string_literal: true

require_relative '../associations'
require_relative '../attribute_access'
require_relative '../deep_copy'
require_relative '../duplicate_keys'
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

      # Largest page size Zammad's generic index endpoints serve, from
      # ApplicationController#model_index_render via CanPaginate. Resources
      # whose endpoint caps lower declare +max_per_page+.
      DEFAULT_MAX_PER_PAGE = 1000

      # Guards the class-level memos on the singleton below. One lock for every
      # resource, because it is held only while a memo is first built.
      MEMO_LOCK = Mutex.new
      private_constant :MEMO_LOCK

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

        # Declares what this resource's search endpoint narrows by, besides
        # the term and the two filters every search reads.
        #
        # Every search endpoint goes through
        # ApplicationController#model_search_render, which hands the same
        # parameters to the search of whichever model it was asked for. What
        # that search does with them is the model's own business. +condition+
        # and +ids+ are read by the part all of them share, CanSearch, and
        # need no declaring. +role_ids+, +group_ids+ and +permissions+ are
        # read by User::Search and by no other: a ticket search handed
        # +group_ids+ takes it, drops it and answers unnarrowed, on the SQL
        # path and the Elasticsearch one alike.
        #
        # Declared rather than accepted everywhere, so that
        # {ResourceProxy#search} can refuse a keyword this resource's search
        # would drop - the same refusal it makes for a keyword no search
        # reads at all.
        #
        # @param names [Array<Symbol>]
        # @return [void]
        def search_filters(*names)
          @search_filters = names.map(&:to_sym).freeze
        end

        # Declares the largest page size this resource's index endpoint
        # serves.
        #
        # @param value [Integer]
        # @return [void]
        def max_per_page(value)
          @max_per_page = value
        end

        # Declares whether this resource's index endpoint sorts.
        #
        # ApplicationController#model_index_render builds its query as
        # `reorder(order_sql).offset(...).limit(...)`: it reads +sort_by+ and
        # +order_by+, pages, and drops every other parameter. That is the
        # default, so a resource says nothing. One whose controller hardcodes
        # the order declares +sortable false+, and {Collection#order} then
        # refuses it rather than handing back records it would be calling
        # sorted.
        #
        # There is no attribute filtering on an index endpoint at all; that
        # is what /search is for.
        #
        # @param value [Boolean]
        # @return [void]
        def sortable(value)
          @sortable = value
        end

        # Declares whether this resource's index endpoint pages.
        #
        # ApplicationController#model_index_render reads +page+ and
        # +per_page+, and every resource this gem models is served by it.
        # That is the default, so a resource says nothing. Not every index
        # is: ObjectManagerAttributesController#index renders
        # `ObjectManager::Attribute.list_full`, every attribute in one
        # response, and reads no parameter at all.
        #
        # Such an index could not be read. A {Collection} asks for the page
        # after a full one, was answered with the same list again, and
        # raised {PaginationError} for it - correctly, as far as it could
        # tell, because an endpoint that ignores +page+ and serves only the
        # first of many pages looks the same. A resource that declares
        # +paginated false+ says which of the two it is: its index is read
        # in one request, and {Collection#page} refuses it.
        #
        # Declare it only for an endpoint that does serve every record. One
        # that caps what it serves and ignores +page+ would be read as far
        # as its cap and no further, with nothing to say so.
        #
        # A search is not affected. Every search endpoint pages.
        #
        # Whether the index sorts is not affected either: that is
        # {.sortable}, a declaration of its own. An endpoint that reads no
        # parameter at all, as the one below, says both.
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
        def resource_path
          declaration(:path) || raise(Error, "#{name} does not declare an API path")
        end

        # @return [Boolean] whether Zammad routes a +/search+ endpoint here
        def searchable? = declaration(:searchable) { false }

        # @return [Array<Symbol>] what this resource's search endpoint narrows
        #   by besides the term, +condition+ and +ids+
        def search_filter_names
          declaration(:search_filters) do
            [] #: Array[Symbol]
          end
        end

        # @return [Integer] the largest page size this endpoint serves
        def page_limit = declaration(:max_per_page) { DEFAULT_MAX_PER_PAGE }

        # @return [Boolean] whether this resource's index endpoint reads
        #   +sort_by+ and +order_by+
        def sortable? = declaration(:sortable) { true }

        # @return [Boolean] whether this resource's index endpoint reads
        #   +page+ and +per_page+
        def paginated? = declaration(:paginated) { true }

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

        # Reads one record by id.
        #
        # On the resource rather than on {ResourceProxy}, because both callers
        # of it need a proxy for nothing else: {ResourceProxy#find} has one,
        # and {Associations::Proxy} was building a throwaway per association
        # read until it grew a second copy of this instead. The resource
        # already knows its member path and how to build itself from a body,
        # which is the whole of the read.
        #
        # @api private
        # @param transport [Transport]
        # @param id [Integer, String]
        # @return [Base]
        def fetch_one(transport, id)
          operation = 'find object'
          response  = transport.get(
            member_path(id),
            operation:      operation,
            resource_class: self,
            query:          { expand: true }
          )
          from_response(transport, response.decoded(:object, operation: operation, resource_class: self))
        end

        # Builds a record that is already stored in Zammad.
        #
        # Straight to the state, past the constructor's refusal of attributes
        # a caller may not stage. Zammad serves +id+ in every body it answers
        # with, and +id+ is the one attribute that refusal exists for.
        #
        # @api private
        # @param transport [Transport]
        # @param attributes [Hash]
        # @return [Base]
        def from_response(transport, attributes)
          record = allocate
          record.send(:setup, transport, attributes)
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
        # Both of the class-level memos here are built under one lock, because
        # a plain `@x ||=` is a write to shared state that two threads can
        # reach at once: on JRuby or TruffleRuby each could see the ivar unset
        # and build a different anonymous proxy class for the same resource,
        # and whichever write lost would still be held by the records already
        # built from it.
        #
        # Populating them eagerly was the earlier answer, first on first use,
        # then in `Client#setup`, then at require time. Each move shrank the
        # window without closing it: `Client.new` is itself something two
        # threads can call, and a resource a caller subclasses themselves -
        # `class MyTicket < Ticket; end`, which this gem supports - is never in
        # any list built ahead of time.
        #
        # The unlocked read first, so the settled case stays a plain ivar read:
        # this is asked on every attribute write, and a lock on that path would
        # cost far more than the one build it guards.
        #
        # @api private
        # @return [Array<Symbol>]
        def belongs_to_foreign_keys
          @belongs_to_foreign_keys || MEMO_LOCK.synchronize { @belongs_to_foreign_keys ||= associations.filter_map { |_, spec| spec[:foreign_key] if spec[:type] == :belongs_to } }
        end

        # The class carrying this resource's association readers, reached
        # through {Base#related}.
        #
        # @api private
        # @return [Class]
        def related_class
          return @related_class if @related_class

          # A resource's proxy inherits its parent's readers, so Base's
          # created_by and updated_by reach every resource. The parent is
          # resolved before the lock is taken, because resolving it may build
          # the parent's own proxy through this same method and a Mutex is not
          # reentrant.
          parent = superclass.respond_to?(:related_class) ? superclass.related_class : Associations::Proxy # steep:ignore NoMethod
          MEMO_LOCK.synchronize { @related_class ||= Class.new(parent) }
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
        #   referenced so that two resources may point at each other. A
        #   resource of this gem by its own name, +'User'+; one a caller
        #   declared by its full name, +'Acme::Role'+
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
        # response, which is what the association endpoints Zammad routes do:
        # TicketArticlesController#index_by_ticket renders every article of
        # the ticket and reads no paging parameter. The reader spends one
        # request and hands back an Array rather than a walking {Collection}.
        #
        # Nothing here can tell a whole list from the first page of one, so
        # declaring this for an endpoint that pages would return that page
        # and no more. This comment used to promise a refusal instead. The
        # check behind that promise read a total from a response header
        # Zammad has never sent, so it never ran, and it was removed for that
        # reason. For an endpoint that pages, declare a resource and walk it
        # as a {Collection}.
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
      # @raise [Error] when an attribute cannot be staged, such as +id+
      # @raise [ArgumentError] when an attribute is named twice, as a String
      #   and as a Symbol, at any depth
      def initialize(transport, attributes = {})
        given = attributes || {}
        # The same refusal the writers make, at the one door that did not make
        # it. `group.id = 99` is refused with a sentence about what an id is
        # for, and `client.groups.new(id: 99)` was accepted in silence - and
        # then `save` POSTed `{"id": 99, ...}`, because a new record is sent in
        # full. So the one spelling that reached the wire was the one nothing
        # checked, and Zammad's answer to it was the first news of the
        # mistake. {.from_response} is the way in for a body Zammad served,
        # which carries an id precisely because it is a record that has one.
        given.each { |key, value| refuse_unwritable!(DeepCopy.symbolize(key), value) }
        setup(transport, given)
      end

      # Gives a +dup+ or +clone+ the state of its own that a write changes.
      #
      # The attributes need nothing done: they are frozen and replaced on
      # write, so a copy sharing them never sees the original's next write.
      # The change set is written in place, and the copy shared it: after
      # +copy = record.dup; copy.name = 'X'+ the original reported
      # +changed?+ and a change to +name+ while still reading +name+ as it
      # was, and its next +save+ sent the copy's value - a change it had
      # never shown.
      #
      # The association proxy goes too. It reads through the record it was
      # built for, so a copy holding the original's would resolve its
      # associations from the original's foreign keys.
      #
      # @api private
      # @param source [Base]
      # @return [void]
      def initialize_copy(source)
        super
        @changes = @changes.dup
        @related = nil
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
        # One proxy for as long as the record lives. What a save, a reload or
        # a write to a foreign key invalidates is what the proxy has resolved,
        # and {#forget_related_targets} empties that where it is held.
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
      # @raise [Error] when an attribute cannot be staged, such as +id+, or
      #   when the record was destroyed. Nothing is staged in either case, so
      #   the record is left as it was.
      # @raise [ArgumentError] when given something that is not a Hash, nil
      #   included, or when an attribute is named twice, as a String and as
      #   a Symbol. Nothing is staged then either.
      def assign_attributes(attributes)
        # Asked before anything else, because everything below is a method
        # of Hash. Nil raised NoMethodError naming `each_with_object`, from
        # inside the gem, and so did `update(params[:group])` with the key
        # missing; an Array of pairs was read as a Hash, by the accident of
        # how it is iterated. Refused rather than read as nothing to assign,
        # which is what the constructor makes of nil: a record built from
        # nothing says so by being empty, and an `update` that staged
        # nothing answers true as if it had stored something.
        raise ArgumentError, "attributes need to be a Hash of names and values, got #{attributes.class}" if !attributes.is_a?(Hash)

        # Two spellings of one attribute are refused before anything is
        # written, for the reason the constructor refuses them - see
        # {DeepCopy.frozen_hash}. Each key is written by its Symbol, so
        # `assign_attributes('name' => 'A', name: 'B')` wrote the attribute
        # twice and kept whichever Hash order put last.
        #
        # A key becomes a Symbol by the constructor's rule, which keeps one
        # that cannot: through `to_sym`, `assign_attributes(1 => 'x')` raised
        # NoMethodError for a Hash `new` takes.
        #
        # The values are copied here as well, which is where a pair inside
        # one of them is refused. Left to the writes below, a value that
        # names a nested key twice raised from the middle of them, with the
        # attributes before it already staged.
        staged = frozen_attributes(DuplicateKeys.normalize(attributes, noun: 'attribute') { DeepCopy.symbolize(it) })

        # rubocop:disable Style/CombinableLoops -- combining them is the bug
        # Two passes on purpose: every key is checked before any of them is
        # written. Combined, `assign_attributes(name: 'X', id: 9, note: 'Y')`
        # staged the name, raised on the id and never reached the note, leaving
        # the record dirty with half a change set - the state `update` takes
        # its own guard one line early to avoid.
        #
        # `write_attribute` checks again for each key, because it is also the
        # direct writer's own guard and cannot assume a caller came through
        # here. That is a second Symbol comparison per attribute, which is not
        # worth a bypass to avoid.
        staged.each { |key, value| refuse_unwritable!(key, value) }
        staged.each { |key, value| write_attribute(key, value) }
        # rubocop:enable Style/CombinableLoops
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

        # What the request carries, held from before it goes out. The
        # attributes are frozen and replaced on write, so this is the Hash the
        # request is built from and stays that whatever is written meanwhile:
        # see #acknowledge_changes!.
        #
        # Built from, and not only held beside. The body of an update used to
        # be read out of the change set a few lines after this was taken, and
        # those are two reads of a record another thread may write to in
        # between: title "B" held here, "C" staged before the body was built,
        # and the PUT carried "C" while an answer nothing could read settled
        # the record on "B" - with nothing staged, so writing "B" again to
        # put it right compared equal and sent nothing. One Hash is read once
        # now, and both the body and what is settled come out of it.
        sent = @attributes

        if new_record?
          response = create_record(sent)
        else
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
          unsaved = unsaved_attributes(sent)
          return true if unsaved.empty?

          response = update_record(unsaved)
        end

        replace_attributes!(response, operation: 'save object', sent: sent)
        true
      end

      # Stages several attributes and saves in one call.
      #
      # @example
      #   ticket.update(state: 'closed', priority: '1 low')
      #
      # @param attributes [Hash] attribute names and their new values
      # @return [Boolean] whether the record was stored
      # @raise [Error] when the record was destroyed, or when an attribute
      #   cannot be staged, such as +id+
      # @raise [ArgumentError] when given something that is not a Hash, nil
      #   included, or an attribute named twice: see {#assign_attributes}
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
      # @raise [Error] when the record was destroyed, or when an attribute
      #   cannot be staged, such as +id+
      # @raise [ArgumentError] when given something that is not a Hash, nil
      #   included, or an attribute named twice: see {#assign_attributes}
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
        raise_if_new!('reload')

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
      # failure, and the association readers all go, and a write to an
      # attribute is refused from then on.
      #
      # Readable as the record last was in Zammad, which is not what dropping
      # the staged changes alone left behind: `reset_pending_state!` empties
      # `@changes` and leaves the writes those changes described standing in
      # `@attributes`, so `group.name = 'B'; group.destroy` answered
      # `changed?` with false, `changes` with `{}` and `name` with "B" - a
      # value Zammad never saw, with nothing left to tell it apart from one it
      # served. `@baseline` is what the record arrived with, and every other
      # path through this state moves the two together.
      #
      # @return [true]
      # @raise [Error] when the record was already destroyed
      # @raise [ResponseError] when Zammad rejected the request
      def destroy
        raise_if_destroyed!('destroy')
        raise_if_new!('destroy')

        transport.delete(member_path, operation: 'destroy object', resource_class: self.class)
        @destroyed  = true
        @attributes = @baseline
        reset_pending_state!
        true
      end

      # Says which record this is and what it holds, with the value of an
      # attribute that names a credential blanked.
      #
      # The attributes were printed as they stood, and a record can hold a
      # credential: `client.users.new(login: 'x', password: 'hunter2')` is
      # how a user is given one. Its `inspect` is what IRB and `pp` show,
      # what an RSpec failure diffs and what an exception report prints for
      # a record it interpolates, so the password staged for one request
      # was written wherever any of those went. The log has blanked the same
      # key in the same request all along, by {Transport.redact}, which is
      # the rule applied here.
      #
      # Only what is printed. {#attributes}, {#to_h} and {#to_json} hand over
      # the values, because sending them is what a record is for.
      #
      # @return [String]
      def inspect = "#<#{self.class.name} id=#{id.inspect} new_record=#{new_record?}#{' destroyed=true' if destroyed?} attributes=#{Transport.redact(attributes).inspect}>"

      protected

      # @see AttributeAccess#installation
      def installation = transport.config.url

      private

      # Everything a record is, in the one place both ways of building one go
      # through. Held apart, {.from_response} would restate this list by hand
      # and the next field added to the constructor would be left unset on
      # every record built from a response - the argument {Client#setup} is
      # written around, one class over.
      #
      # @return [void]
      def setup(transport, attributes)
        @transport  = transport
        @attributes = frozen_attributes(attributes)
        # What #changes measures against: the attributes this record arrived
        # with, kept apart from the ones it currently holds. The two share the
        # one frozen Hash until the first write copies it.
        @baseline   = @attributes
        @changes    = {}
        @new_record = true
        @destroyed  = false
        @error      = nil
        @related    = nil
        # Whether what this record holds came back from a save rather than
        # from a read. Only {#no_id_message} asks, and only for a record left
        # without an id, where the two lead somewhere quite different.
        @saved      = false
      end

      def mark_persisted!
        @new_record = false
      end

      # Refuses an operation on a record Zammad never had.
      #
      # `destroyed?` was the only thing these asked, so a record built with an
      # id it was simply handed - `client.groups.new(id: 99)`, which the
      # attribute writers refuse but the constructor still allows - reported
      # `new_record?` true and `persisted?` false and then issued a real DELETE
      # against group 99. The id addresses a record this one does not stand
      # for, and nothing about it came from Zammad.
      def raise_if_new!(operation)
        raise Error, "#{self.class.name} has not been saved, so there is nothing to #{operation}" if new_record?
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

      # Asked by {#write_attribute} and by {AttributeAccess#respond_to_missing?},
      # so that a record never claims a writer it would then refuse. That is
      # the invariant the writer branch of `respond_to_missing?` exists for.
      def attribute_writable?(key) = key != :id

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
      #
      # +sent+ is what a save was sent with, and is what tells one from a
      # read.
      def replace_attributes!(response, operation:, sent: nil)
        # First, while #new_record? still says whether this was a create.
        acknowledge_changes!(sent) if sent
        @new_record = false
        @saved      = !sent.nil?
        @attributes = frozen_attributes(response.decoded(:object, operation: operation, resource_class: self.class))
        @baseline   = @attributes
        reset_pending_state!
      end

      # The same argument, for what was staged: a 2xx is Zammad saying it
      # applied the changes, whether or not the rest of the answer parsed.
      #
      # They used to stay staged until the body had decoded. An update
      # answered with a 2xx nothing could read - the same proxy page - raised
      # ParseError with the whole change set still in place, so the next
      # `save` sent all of it again along with whatever had been staged
      # since. For most attributes that is the same value twice. For a
      # ticket's `article` it is a second article, and a second e-mail to
      # the customer: the one write {Transport::RETRIABLE_METHODS} leaves
      # PUT out to keep from being repeated, repeated by the caller's next
      # unrelated save instead.
      #
      # So the baseline moves up to what was sent, before the body is read.
      # If that then raises, the record holds the values it sent and nothing
      # staged: it is not what Zammad would serve - `updated_at` is behind,
      # and anything Zammad derived is missing - and {#reload} is what
      # brings that in. A save Zammad rejected never gets here, so what it
      # was sent stays staged to be corrected and sent again.
      #
      # What was sent, and not what the record holds by the time the answer
      # is in. The two differ where the record was written to while the
      # request was out - by a logger or a middleware of the caller's that
      # reaches the record, or by another thread - and the baseline used to
      # be taken from the record as it then stood: a PUT that carried title
      # "B", with "C" staged before the answer came, left the record reading
      # "C" with nothing staged, so the next `save` reported true without a
      # request for a value Zammad was never sent. A write made meanwhile is
      # dropped instead, which is what a response that can be read does to
      # it: the attributes it carries replace the record's, whatever was
      # written to them since the request left.
      #
      # And of what was sent, only the attributes Zammad has served this
      # record with. A key written since that it never sent back is not known
      # to be an attribute at all. A ticket's `article` is the case that
      # matters: a command that travels in the body of the same PUT and makes
      # an article, and no part of what a ticket is served as. Settled into
      # the baseline with the rest, it was remembered as the ticket's own
      # state, so the same article assigned again - a second reply with the
      # text of the first - compared equal to it, staged nothing, and `save`
      # reported true without a request. A response that can be read leaves
      # no such key behind, and neither does this.
      #
      # A record being created has nothing it was served with to measure
      # against, and keeps all it sent. It has no id to be saved again by,
      # so there is no second request for a key to be missing from.
      #
      # What the association proxy has resolved goes with the attributes it
      # was resolved from. This puts the record back on what it sent, which
      # is a write to every attribute at once, and it was the one write to a
      # foreign key that left the proxy alone: `customer_id` sent as 9,
      # written to 10 while the request was out and `related.customer` read
      # then, and the record was back on 9 with user 10 still memoized as
      # its customer. {#reset_pending_state!} empties the proxy too, but
      # only once the body has decoded, and a body that does not is what
      # this method is here for.
      def acknowledge_changes!(sent)
        settled     = new_record? ? sent : sent.slice(*@baseline.keys).freeze
        @attributes = settled
        @baseline   = settled
        @changes    = {}
        forget_related_targets
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
        forget_related_targets
      end

      # Empties the association proxy, rather than dropping it.
      #
      # Dropping it was the earlier answer: `@related = nil`, and the next
      # call to {#related} built a fresh one. That reached every caller who
      # asked again and none who had kept what they were handed, so after
      # `related = ticket.related` a reload, a save or `ticket.customer_id = 9`
      # left `related.customer` answering with the record it had resolved
      # before - the stale read these calls exist to prevent, one variable
      # away from where it was fixed.
      def forget_related_targets
        @related&.send(:forget_targets)
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
      #
      # A destroyed record takes no writes. `update` has refused one all
      # along, so as not to leave a change set that can never be sent, but
      # the writers themselves did not ask: `group.destroy; group.name = 'Z'`
      # left `changed?` true and `name` reading "Z" on a record `destroy`
      # promises to leave as it last was in Zammad, and the `save` after it
      # was the first thing to object. Asked here, it holds for a named
      # writer, `[]=` and `assign_attributes` alike, since all three write
      # through this method.
      def write_attribute(key, value)
        raise_if_destroyed!('change')
        refuse_unwritable!(key, value)

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
        # from. `replace_attributes!` forgets them on save and reload, but
        # the write that actually changes a foreign key did not, so
        # `ticket.customer_id = 9` left `ticket.related.customer` answering
        # with user 3 and no request to show for it. Every target goes:
        # evicting one reader means reaching into the cache by name for a
        # saving that is one request at most.
        forget_related_targets if self.class.belongs_to_foreign_keys.include?(key)
        staged
      end

      # The attributes of +held+ that differ from what this record arrived
      # with, which is what an update sends.
      #
      # The same question {#write_attribute} asks before it stages a change,
      # asked of one Hash of attributes rather than of the change set: see
      # {#save!} for why the body of a request is not read from there.
      #
      # @param held [Hash{Symbol => Object}] attributes of this record
      # @return [Hash{Symbol => Object}]
      def unsaved_attributes(held)
        baseline = @baseline

        held.reject { |key, value| baseline.key?(key) && baseline[key] == value }
      end

      def create_record(body)
        transport.post(
          self.class.resource_path,
          operation:      'save object',
          resource_class: self.class,
          query:          { expand: true },
          body:           body
        )
      end

      def update_record(body)
        transport.put(
          member_path,
          operation:      'save object',
          resource_class: self.class,
          query:          { expand: true },
          body:           body
        )
      end

      # The id is what addresses the record, so it is not an attribute a caller
      # stages. Written, it took effect immediately for every path that builds
      # a URL from `@attributes` and not at all for the record those paths then
      # reported on: `group.id = 99; group.destroy` sent DELETE to group 99 and
      # left the record saying group 1 was the one destroyed. Zammad would not
      # have applied it either - an id is not something its endpoints let you
      # set - so there is no call here that a refusal takes away.
      def refuse_unwritable!(key, value)
        return if attribute_writable?(key)

        message = "#{self.class.name}##{key} cannot be staged as an attribute"
        # `attribute_writable?` is a hook a resource may override, so the
        # reason belongs to the key that was refused rather than to the raise.
        if key == :id
          message += ', because it is what addresses this record; look up the record you meant ' \
                     "with find(#{value.inspect})"
        end
        raise Error, message
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

      # A record has no id in three quite different situations, and one message
      # for more than one of them sends people looking in the wrong place.
      #
      # Before the first save there is simply nothing to address yet.
      #
      # After one there is - Zammad answered 2xx, so the record is in Zammad -
      # but the response carried no id to address it by, which is what
      # {#replace_attributes!} leaves behind when a 2xx body does not decode
      # as the object it claims to be.
      #
      # And a record can arrive without one from a plain read: Zammad reduces
      # the object it serializes for a permission-scoped client, which is the
      # same thing {#write_attribute} is written around. Such a record is
      # persisted, so it used to be told it "was saved" - pointing the caller
      # at a save that never happened, when what they need to look at is which
      # user the client authenticates as.
      def no_id_message
        return "#{self.class.name} has no id, save it first" if new_record?

        if @saved
          return "#{self.class.name} was saved, but the response carried no id to address it by, " \
                 'so this record cannot act on the server. Look it up again to get one that can.'
        end

        "#{self.class.name} was loaded without an id, so this record cannot act on the server. " \
          'Zammad serves a reduced object where the authenticated user may not see the whole record, ' \
          'so check what this client may read, then look it up again to get one that can.'
      end
    end
  end
end
