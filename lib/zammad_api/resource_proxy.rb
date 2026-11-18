# frozen_string_literal: true

require 'forwardable'

require_relative 'collection'
require_relative 'deep_copy'
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

    # What every one of Zammad's search endpoints narrows by besides the term:
    # the two parameters that CanSearch, the part all of them share, reads out
    # of the call ApplicationController#model_search_render makes into
    # Model.search. Unlike an index endpoint a search does narrow, but through
    # these parameters and the term - never through an attribute name of its
    # own.
    #
    # That call hands over +role_ids+, +group_ids+ and +permissions+ as well,
    # and they used to be in this list for it. Only the user search reads
    # them, so a resource says which of them its search takes: see
    # {Resources::Base.search_filters}.
    SEARCH_FILTER_KEYS = %i[condition ids].freeze

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

    # Fetches the first record carrying all of these attribute values, from
    # the candidates Zammad hands over: nil if none of them does.
    #
    # It answers for every resource and every kind of value. Where it walks
    # the index, the candidates are every record this client can read, and nil
    # means there is no such record. Where it searches, they are the hits, and
    # nil means no hit carried the values - which is the same thing only for a
    # value the search looks at. See "What the search can surface" below for
    # which those are. Zammad cannot be asked the question directly -
    # its index endpoints do not filter: ApplicationController#model_index_render
    # sorts and pages and drops every other parameter, so a query parameter on
    # the index, which is how this was first written, asked for
    # +email=someone@example.com+ and got back the whole user index, of which
    # it returned the first record. So the candidates are fetched and checked
    # here, and there are two ways to fetch them:
    #
    # - A search, where the resource has a search endpoint and one of the
    #   values is a string to search on. That is the cheap way: Zammad narrows
    #   the candidates, and only the hits are read.
    # - A walk of the index, everywhere else: +ticket_states+,
    #   +ticket_priorities+ and +ticket_articles+, which Zammad routes no
    #   search endpoint for, and a lookup such as +find_by(active: true)+ or
    #   +find_by(organization_id: 5)+ that has no string in it. That costs a
    #   request per page of records until one matches, and the whole index for
    #   a miss - nothing for a list of ticket states, and worth knowing before
    #   it is run against every ticket on an instance.
    #
    # Both used to be refused instead: a resource without a search endpoint
    # raised, and so did a lookup without a string value. The caller was left
    # to write +all.detect { ... }+, which is the walk this now makes, so the
    # refusals kept nothing from happening and made +find_by+ a method that
    # worked on four resources out of seven.
    #
    # Values are compared exactly, and against the record as Zammad stores it:
    # +find_by(email: 'Someone@Example.com')+ does not match a login Zammad
    # downcased. A record that does not carry an attribute does not match it,
    # whatever the value - not even +nil+, which would otherwise match every
    # record a misspelled name was asked of.
    #
    # The search term is one string value. Zammad searches by word, so a value
    # of another type would go out as the word it prints as: +find_by(active:
    # true)+ searched for "true" and matched records carrying that word, which
    # is essentially none of them. Such a value is compared here instead.
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
    # Which values those are depends on the backend. Elasticsearch looks for
    # the term in everything a record is indexed with. Without it the term is
    # matched by the SQL LIKE mentioned above, and that reads a fixed set of
    # columns: CanSearch takes the string columns of the model's own table,
    # which covers users, organizations and groups, and Ticket::Search
    # replaces that with the ticket's title and number and the from, to,
    # subject and body of its articles. A name +expand+ adds for an
    # association is not a column at all. So on such an instance
    # +tickets.find_by(state: 'open')+, a ticket looked up by a custom
    # attribute, and +users.find_by(organization: 'Acme')+ are searches for a
    # word in fields that do not hold the value. They find the record only
    # where the word happens to appear in one of those fields too, and
    # otherwise answer nil for a record that exists.
    #
    # There is no walk of the index after a search that found nothing, which
    # would close that gap. A miss is the ordinary case for what this is most
    # used for - +find_by(email: ...) || create(...)+ on an address that is
    # new - and the walk would turn each of them into a read of every user on
    # the instance, a thousand to the request, to confirm what the search had
    # already said correctly. Nothing here can tell that miss from one caused
    # by a field the search does not read, because nothing in a response says
    # which backend answered. The caller does know which lookup they are
    # writing: +detect { ... }+ on the resource is the walk, over every
    # record this client may read. Compared with +[]+ there, as it is below,
    # because a reader raises for an attribute the record in hand does not
    # carry and would end the walk on it.
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
    #   client.ticket_states.find_by(name: 'open')
    #   client.users.find_by(organization_id: 5, active: true)
    #
    # @param params [Hash] attribute names and the values to match exactly
    # @return [Resources::Base, nil] nil when nothing matched
    # @raise [ArgumentError] when no attribute was given
    def find_by(**params)
      raise ArgumentError, 'find_by needs at least one attribute to match' if params.empty?

      term       = resource_class.searchable? ? search_term_for(params) : nil
      candidates = term ? search(term) : all

      candidates.detect { |record| params.all? { |key, value| record.key?(key) && record[key] == value } }
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
    # That goes for a keyword another resource's search reads, too.
    # +role_ids:+, +group_ids:+ and +permissions:+ narrow a user search and no
    # other, and +client.tickets.search('printer', group_ids: [2])+ was sent
    # as written and answered with tickets from every group the client can
    # read. Tickets are narrowed by group through a +condition+ on
    # +ticket.group_id+.
    #
    # +group_ids:+ comes in two forms, and they do not ask for the same
    # thing. User::Search walks it as pairs of a group and an access, and
    # HasGroups.group_access reads an access that is missing as +full+. So a
    # list of ids, which names none, is the agents with full access to those
    # groups, and +group_ids: [2]+ leaves out an agent who may only read
    # group 2. A Hash names the access for each group, and +full+ always
    # counts as having it: +group_ids: {2 => ['read']}+ is every agent with
    # read or full access to group 2.
    #
    # A keyword with nothing in it is refused as well: an empty list, an
    # empty Hash, a blank String. Zammad reads each of those as the keyword
    # not having been given, the way it reads one it does not know. CanSearch
    # narrows by +ids+ only where +params[:ids].present?+, so
    # +search('smith', ids: allowed_ids)+ with no id allowed came back with
    # every user matching the term, where the caller had asked for none of
    # them. +role_ids+, +group_ids+ and +permissions+ are skipped the same
    # way where the search runs through Elasticsearch, and an empty
    # +condition+ does not reach the request at all.
    #
    # +permissions:+ is not an access check, and is sent as it is given all
    # the same, because what it does is Zammad's to decide. User::Search
    # resolves it to the roles granting one of the permissions and adds them
    # to +role_ids+, so the two together widen each other. On the
    # Elasticsearch path the role clause is then written only where there is
    # a role to put in it: a permission no active role grants - a misspelt
    # one, or one nobody has been given - resolves to none, the clause is
    # left out, and the search answers with every user matching the term.
    # The SQL path joins the roles against the empty list and answers with
    # nobody. Nothing in a response says which path answered, and a user
    # record carries role ids rather than permissions, so there is nothing
    # here to check the hits against. +role_ids:+ with at least one id
    # narrows on both paths.
    #
    # +role_ids:+ is no access check either. Both paths ask who holds the
    # role - the SQL one joins the roles a user has, the Elasticsearch one
    # matches the role ids a user is indexed with - and neither asks whether
    # the role is active, which is what Zammad asks before it grants
    # anything through one: Role.with_permissions leaves a disabled role
    # out. Neither asks whether the user is active. So a user matches a role
    # that grants nothing any more, and the hits are who to look at, not who
    # may.
    #
    # @example
    #   client.users.search('smith')
    #   client.users.search('smith', role_ids: [2])
    #   client.users.search('smith', group_ids: [2])             # full access to group 2
    #   client.users.search('smith', group_ids: {2 => ['read']}) # read or full access to it
    #   client.tickets.search('printer', condition: {'ticket.state_id' => {operator: 'is', value: [1, 2]}})
    #   client.tickets.search('state.name:open').order(created_at: :desc)
    #
    # @param term [String] the Zammad search term
    # @param filters [Hash] +condition:+ and +ids:+ on every search, and on
    #   users +role_ids:+, +permissions:+ and +group_ids:+ - the last as a
    #   list of group ids, for agents with full access to them, or as a Hash
    #   of group id to +read+, +create+, +change+, +overview+ or +full+, one
    #   or several
    # @return [Collection]
    # @raise [ArgumentError] when +term+ is not a non-empty string, or for a
    #   keyword the search endpoint does not read, a nil value, a keyword
    #   with nothing in it, two spellings of one key, or a list a query
    #   string cannot carry: see {Transport.stringify_query_list}
    # @raise [Error] when Zammad routes no search endpoint for this resource
    def search(term, **filters)
      searchable!
      raise ArgumentError, 'search needs a non-empty query string' if !term.is_a?(String) || term.strip.empty?

      collection(
        "#{path}/search",
        'get .search of object',
        # A copy of the term and the filters, taken here. The collection is
        # lazy, so it reads them when it is enumerated, and it was reading the
        # caller's own objects: `search('printer', ids: ids)` followed by
        # `ids << 7`, or a term built up in a buffer that is then reused,
        # searched for something other than what this call was given - after
        # it had been checked, and with the collection already handed on.
        query:        DeepCopy.frozen_copy({ query: term }.merge(search_filters(filters))),
        max_per_page: SEARCH_MAX_PER_PAGE,
        sortable:     true,
        search:       true
      )
    end

    def inspect = "#<#{self.class.name} #{resource_class.name}>"

    private

    def collection(path, operation, query: {}, max_per_page: resource_class.page_limit, sortable: resource_class.sortable?, search: false)
      Collection.new(
        transport:       @transport,
        resource_class:  resource_class,
        path:            path,
        operation:       operation,
        max_per_page:    max_per_page,
        sortable:        sortable,
        unsortable_hint: resource_class.searchable? ? SEARCHABLE_UNSORTABLE_HINT : UNSORTABLE_HINT,
        search:          search,
        query:           { expand: true }.merge(query)
      )
    end

    # The keywords of a search, checked at the call that wrote them.
    #
    # Through {Transport.stringify_query} for the refusals it makes at any
    # depth - a nil value, two spellings of one key inside a +condition+,
    # and a list of conditions a query string cannot keep apart - because
    # left to the request they would be reported when the collection is
    # first enumerated, some lines away from the search that wrote them.
    # What it returns is discarded: the collection sends the values as they
    # were given - a copy of them, see {#search} - and the transport
    # stringifies them then.
    #
    # @return [Hash{Symbol => Object}]
    # @raise [ArgumentError]
    def search_filters(filters)
      normalized = DuplicateKeys.normalize(filters) { it.to_s.to_sym }
      unknown    = normalized.keys - search_filter_keys
      raise ArgumentError, unknown_search_filter_message(unknown) if !unknown.empty?

      Transport.stringify_query(normalized)

      empty = normalized.select { |_, value| empty_search_filter?(value) }
      raise ArgumentError, empty_search_filter_message(empty) if !empty.empty?

      normalized
    end

    # Whether Zammad would read a keyword's value as the keyword not having
    # been given: what Rails calls blank, for the types a filter comes in.
    # Asked of the keyword's own value and not of what is nested in it - a
    # +condition+ naming an attribute with an empty +value+ is a selector,
    # and what that selects is Zammad's to say.
    #
    # Blank as Rails reads it, Unicode spaces included: see
    # {Transport::BLANK}.
    def empty_search_filter?(value)
      case value
      when String      then Transport::BLANK.match?(value)
      when Array, Hash then value.empty?
      else false
      end
    end

    def empty_search_filter_message(empty)
      given = empty.map { |name, value| "#{name}: #{value.inspect}" }.join(', ')

      "search was given #{given} on #{path}, and Zammad reads a keyword with nothing in it as one that was not given: " \
        'the search would come back with everything matching the term, not narrowed to nothing. ' \
        'Leave the keyword out to search without it, and skip the search where there is nothing it may find.'
    end

    # What the search endpoint of this resource narrows by besides the term.
    #
    # @return [Array<Symbol>]
    def search_filter_keys = SEARCH_FILTER_KEYS + resource_class.search_filter_names

    def unknown_search_filter_message(unknown)
      "search does not take #{unknown.join(', ')} on #{path}: this search endpoint narrows by the term, and by #{search_filter_keys.join(', ')}, " \
        'and drops anything else, which would hand back an unnarrowed search. ' \
        "Put an attribute value in the term - search('state.name:open') - or in a condition - " \
        "search(term, condition: {'ticket.group_id' => {operator: 'is', value: [2]}}) - " \
        'sort with search(term).order(...), and page with page, in_batches or find_each.'
    end

    # Zammad routes a search endpoint per model, not for every model: users,
    # organizations, tickets and groups have one, ticket states, ticket
    # priorities and ticket articles do not. Asking one of the latter for
    # `.../search` is a 404, which would arrive as a NotFoundError about a
    # record from a call that asked for a list.
    def searchable!
      return if resource_class.searchable?

      raise Error, "Zammad routes no search endpoint for #{resource_class.name}, so it cannot be searched by term: #{path}/search answers 404, which would arrive here as a NotFoundError about a record. Look one record up by attribute value with find_by, which walks the records where it cannot search, or pick several out with select { ... }."
    end

    # The one value {#find_by} searches on: the longest, as the most selective
    # of them, which matters because a miss reads every page of hits.
    #
    # One value rather than all of them joined, and unquoted - both spellings
    # find nothing on an instance without Elasticsearch, for the same reason.
    # See {#find_by}.
    #
    # @return [String, nil] nil when no value can be searched on, in which
    #   case the index is walked instead
    def search_term_for(params) = params.values.grep(String).reject { it.strip.empty? }.max_by(&:length)

    def path = resource_class.resource_path

    def member_path(id) = resource_class.member_path(id)
  end
end
