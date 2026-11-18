# frozen_string_literal: true

require_relative 'errors'

module ZammadAPI
  # A lazily fetched, automatically paginated list of records.
  #
  # Nothing is requested until the collection is iterated. {#order} and
  # {#page} return new collections, so a collection can be built up in
  # steps and shared without being disturbed.
  #
  # {#each} walks every page until the server runs out of records, so it is
  # safe to iterate a collection larger than one page. {#first} reads one page
  # sized for what it was asked for, and +lazy+, +detect+ and the rest of
  # +Enumerable+ stop the walk as soon as they have enough, so neither has to
  # download everything.
  #
  # @example Iterate every ticket
  #   client.tickets.all.each { |ticket| puts ticket.title }
  #
  # @example Narrow to matches, then stop after the first five
  #   client.tickets.search('state.name:open').first(5)
  #
  # @example Sorted by the server
  #   client.groups.order(:name).each { |group| puts group.name }
  #
  # @example Work in batches, e.g. for an import
  #   client.tickets.all.in_batches(of: 50) { |tickets| import(tickets) }
  #
  # @example One explicit page
  #   client.tickets.all.page(2, per_page: 50).to_a
  class Collection
    include Enumerable

    # The two directions a sort can run in, as Zammad spells them.
    SORT_DIRECTIONS = %w[asc desc].freeze
    private_constant :SORT_DIRECTIONS

    # What an attribute to sort by is named. Zammad takes several of them as
    # one comma-separated parameter, so a name carrying a comma or a space
    # would be read as something other than the one attribute it was.
    SORT_ATTRIBUTE = /\A\w+\z/
    private_constant :SORT_ATTRIBUTE

    # @api private
    # @param per_page [Integer, nil] records fetched per request, or nil for
    #   as many as the endpoint serves
    # @param search [Boolean] whether this is a search endpoint, which
    #   differs from an index in two ways a collection has to know about: it
    #   reports the size of the whole result, alone for +only_total_count+
    #   and beside a page for +with_total_count+, and it can serve a page
    #   short of its size, or with nothing on it, before the last one
    # @param sortable [Boolean] whether this endpoint reads +sort_by+ and
    #   +order_by+
    # @param unsortable_hint [String] what to do instead where it does not
    # @param widens [Boolean] whether a walk may ask for a larger page than
    #   +per_page+ once one has come back with nothing on it, which a read
    #   sized by {#first} may and a batch size a caller chose may not: see
    #   {#widened}
    def initialize(transport:, resource_class:, path:, operation:, max_per_page:, sortable:, unsortable_hint:, query: {}, per_page: nil, page: nil, search: false, widens: false)
      @transport       = transport
      @resource_class  = resource_class
      @path            = path
      @operation       = operation
      @query           = query
      @max_per_page    = max_per_page
      @sortable        = sortable
      @unsortable_hint = unsortable_hint
      # As many as the endpoint serves, unless a call asks for another size.
      #
      # A fixed default of 100 was the earlier answer, and it cost a request
      # for every 100 records where the endpoint would have served 1000: a
      # walk of the user index spent ten times the round trips it needed, and
      # each of those is a TLS handshake of its own under Faraday's default
      # adapter. The endpoint's own cap is the one number that is right for
      # every resource without a caller looking each of them up - it is
      # already what {#clamp_per_page} measures against.
      #
      # What that costs is a larger page held at once - a thousand expanded
      # users rather than a hundred. {#first} is what made that affordable:
      # the cheap-looking call that only wants a record or two now sizes its
      # own page instead of taking them off the front of this one.
      @per_page        = clamp_per_page(per_page || max_per_page)
      @page            = page
      @search          = search
      @widens          = widens
    end

    # Yields every record, fetching further pages as needed.
    #
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    def each(&block)
      return to_enum(:each) if !block

      in_batches { |records| records.each(&block) }
      self
    end

    # Yields every record, like {#each}, with the page size set inline.
    #
    # @param batch_size [Integer, nil] records fetched per request
    # @yieldparam record [Resources::Base]
    # @return [Enumerator] when no block is given
    def find_each(batch_size: nil, &block)
      return to_enum(:find_each, batch_size: batch_size) if !block
      return with(per_page: page_size!(batch_size, 'batch_size')).find_each(&block) if batch_size

      each(&block)
    end

    # Yields one array of records per page.
    #
    # A batch is one response: what a request returned is what the block gets,
    # so +of+ is what sizes it. For groups of a size the API knows nothing
    # about, slice the records instead: +find_each.each_slice(12)+.
    #
    # @param of [Integer, nil] records fetched per request
    # @yieldparam records [Array<Resources::Base>]
    # @return [Enumerator] when no block is given
    def in_batches(of: nil, &block)
      return to_enum(:in_batches, of: of) if !block
      return with(per_page: page_size!(of, 'of')).in_batches(&block) if of

      walk(&block)
      self
    end

    # Returns a new collection limited to a single page.
    #
    # +per_page+ decides how big that page is, and so which records it holds:
    # +page(2, per_page: 50)+ is records 51 to 100. A size larger than the endpoint
    # serves is refused rather than reduced, because reducing it moves the
    # page: +page(3, per_page: 500)+ against an endpoint capping at 100 was sent as
    # +page=3&per_page=100+ and answered with records 201 to 300 instead of
    # 1001 to 1500. A job that checkpoints a page number then re-read what it
    # had already handled and never reached the rest.
    #
    # @example
    #   client.tickets.all.page(2, per_page: 50).to_a
    #
    # @param number [Integer] one-based page number
    # @param per_page [Integer, nil] records on the page, as many as the endpoint
    #   serves by default
    # @return [Collection]
    # @raise [ArgumentError] for a page size the endpoint does not serve
    def page(number, per_page: nil)
      raise ArgumentError, 'page needs to be a positive integer' if !number.is_a?(Integer) || !number.positive?
      return with(page: number) if per_page.nil?

      size = positive_integer!(per_page, 'per_page')
      raise ArgumentError, "#{@path} serves at most #{@max_per_page} records per page, so page(#{number}, per_page: #{size}) would be sent as page #{number} of #{@max_per_page} and hold different records. Ask for page(#{number}, per_page: #{@max_per_page}) or fewer, or walk the records with find_each." if size > @max_per_page

      with(page: number, per_page: size)
    end

    # Returns a new collection sorted by the server.
    #
    # Attributes named on their own sort ascending, and a keyword says which
    # way one runs, the way ActiveRecord reads the same call. A second
    # +order+ sorts within the first, so +order(:active).order(name: :desc)+
    # is +order(:active, name: :desc)+.
    #
    # This is the one thing an index endpoint does besides paging, which is
    # why it has a name of its own. It used to be reached as
    # +where(sort_by: 'name', order_by: 'desc')+, on a method that refused
    # nearly everything else it was given: an index endpoint does not filter
    # by attribute value, so +where(state: 'open')+ could only raise, and on
    # tickets and users +where+ accepted nothing at all. Narrowing by a value
    # is what {ResourceProxy#search} and {ResourceProxy#find_by} are for.
    #
    # Not every endpoint sorts. +/api/v1/tickets+ and +/api/v1/users+ are
    # always served in id order, and drop +sort_by+ along with everything
    # else they do not read, so this refuses them rather than handing back
    # records it would be calling sorted. A search does sort, for every
    # resource that can be searched.
    #
    # @example
    #   client.groups.order(:name).first(5)
    #   client.organizations.order(name: :desc)
    #   client.tickets.search('state.name:open').order(:priority_id, created_at: :desc)
    #
    # @param attributes [Array<Symbol, String>] attributes to sort by,
    #   ascending
    # @param directions [Hash{Symbol => Symbol, String}] attributes to sort by,
    #   each with +:asc+ or +:desc+
    # @return [Collection]
    # @raise [ArgumentError] for an endpoint that does not sort, no
    #   attribute at all, an attribute named twice, or a direction that is
    #   neither +:asc+ nor +:desc+
    def order(*attributes, **directions)
      raise ArgumentError, "#{@path} is always served in the same order and ignores sort_by, so order would hand back the records as they were. #{@unsortable_hint}" if !@sortable

      requested = sort_columns(attributes, directions)
      raise ArgumentError, 'order needs at least one attribute to sort by: order(:name), or order(name: :desc)' if requested.empty?

      sorted   = sorted_by
      repeated = requested.keys & sorted.keys
      raise ArgumentError, "order was given #{repeated.join(', ')}, which this collection is already sorted by" if !repeated.empty?

      columns = sorted.merge(requested)
      with(query: @query.merge(sort_by: columns.keys.join(','), order_by: columns.values.join(',')))
    end

    # Reads one or more attributes from every record.
    #
    # Zammad has no way to ask an index endpoint for a subset of the fields, so
    # this shapes the result rather than shrinking the request.
    #
    # @example
    #   client.users.all.pluck(:email)          # => ["a@example.com", ...]
    #   client.tickets.all.pluck(:id, :title)   # => [[1, "Help"], ...]
    #
    # @param keys [Array<Symbol, String>] attribute names
    # @return [Array] one value per record for a single key, one array of
    #   values per record for several
    # @raise [ArgumentError] when no attribute name was given
    def pluck(*keys)
      raise ArgumentError, 'pluck needs at least one attribute name' if keys.empty?
      return map { it[keys.first] } if keys.one?

      map { |record| keys.map { record[it] } }
    end

    # The first record, or the first +count+ of them.
    #
    # Sized to what was asked for, which +Enumerable#first+ cannot be: it
    # takes its records off the front of a page this collection sized for
    # walking, so +all.first+ downloaded a page of a thousand users to hand
    # back one of them.
    #
    # The request is sized, not the collection. Limiting it to one page of
    # +count+ records would have been the shorter way to write this and
    # answers wrongly where the endpoint serves a smaller page than the
    # +max_per_page+ this resource declares: +first(500)+ against a server
    # capping at 100 came back with 100 records and nothing to say that the
    # other 400 were there to be read. Sizing the request instead leaves the
    # walk able to fetch a second page, and +Enumerable#first+ stops it as
    # soon as it has what it asked for - so the ordinary case is still the one
    # request it looks like.
    #
    # A collection {#page} already limited is left as it is. Its page size
    # says which records it holds, so re-sizing it would move them - the same
    # reason {#page_size!} refuses to.
    #
    # The size is where the read starts, and not what it is held to. A
    # search can serve a page with nothing on it and hits still behind it,
    # and a read that stayed this small then paid a request for every one
    # of them: see {#widened}.
    #
    # A read that sizes its own request leaves out a record it has already
    # handed over. The larger pages it asks for past an empty one are where
    # an endpoint that pages smaller than it is asked hands a hit back twice,
    # and a caller acting on the records - `first(5).each { notify(it) }` -
    # would act on that one twice. It holds no more ids than records wanted,
    # and asks for nothing more to do it: the read goes on to the next
    # record, as it does past a stale hit.
    #
    # @param count [Integer, nil] how many records to read
    # @return [Resources::Base, Array<Resources::Base>, nil] one record, or an
    #   array of them when +count+ was given
    def first(count = nil)
      wanted  = count || 1
      # Through an enumerator rather than `super`, so that the sized
      # collection does the reading and this method is not asked to be both
      # the caller and the callee of Enumerable#first.
      records = own_request_for_first?(wanted) ? with(per_page: wanted, widens: true).to_enum(:each_distinct) : each
      count.nil? ? records.first : records.first(count)
    end

    # The first +count+ records, read the way {#first} reads them.
    #
    # +take(n)+ and +first(n)+ ask one question, and +Enumerable+ answers both
    # by taking records off the front of a page this collection sized for
    # walking. With {#first} sizing its own request and this one left alone,
    # what the same read cost depended on which of the two words was typed.
    #
    # @param count [Integer] how many records to read
    # @return [Array<Resources::Base>]
    def take(count)
      # Enumerable#take always answers with an Array, and {#first} only does
      # when it is given a count - a nil is "just the one" there. Refused with
      # the error Enumerable#take raises for it, rather than quietly answering
      # a different question with a different type.
      raise TypeError, 'no implicit conversion from nil to integer' if count.nil?

      first(count)
    end

    # +Enumerable#find+, which takes a block.
    #
    # Defined only to refuse the other reading of it. {ResourceProxy#find}
    # takes an id - +client.tickets.find(1)+ is the lookup by id - and the same
    # word on a collection is +Enumerable#find+, whose argument is an ifnone
    # callable rather than an id. So +client.tickets.all.find(1)+ made no
    # request, raised nothing, and answered with an Enumerator: a silent
    # no-op, on the one spelling a caller is most likely to reach for.
    #
    # A collection cannot do the lookup either, even where it would be
    # unambiguous - a search has already narrowed what it holds, so an id
    # found through one collection would mean something different from an id
    # found through another.
    #
    # @yieldparam record [Resources::Base]
    # @return [Resources::Base, nil]
    # @raise [ArgumentError] when given an id where a block belongs
    def find(*args, &block)
      raise ArgumentError, find_by_id_message(args.first) if block.nil? && !args.empty?

      super
    end

    # Number of records in this collection.
    #
    # One request on a search, which Zammad can count without serving the
    # records: +only_total_count+ is the first thing
    # ApplicationController#model_search_render looks at, and it answers with
    # the figure alone.
    #
    # Every other endpoint has to be walked. An index endpoint drops
    # +only_total_count+ along with every other parameter it does not know -
    # model_index_render reads +sort_by+, +order_by+ and the paging and
    # nothing else - and there is no header to read a total from either, so
    # there is nothing cheaper to ask. Probing anyway cost a wasted request
    # before the walk that had to happen regardless.
    #
    # @return [Integer]
    def count(*args, &block)
      # A block or an argument is Enumerable counting matches, not this asking
      # how large the result is. A collection limited to one page has to read
      # that page, because the total describes the whole query.
      return super if !args.empty? || block || @page || !@search

      total_count || super
    end

    # Number of records in this collection.
    #
    # An alias of {#count}, and so the same cost: one request on a search
    # endpoint, a walk of every page on any other.
    #
    # @return [Integer]
    # @see #count
    alias size count

    # @return [Integer]
    # @see #count
    alias length count

    # Whether this collection has no records.
    #
    # Costs the one request {#first} costs: a page of a single record, except
    # on a collection limited to one page, where the page size decides which
    # records that page holds and so cannot be narrowed. A search whose
    # first hits have lost their records costs the few more it takes to read
    # past them.
    #
    # @example
    #   client.tickets.search('state.name:merged').empty?
    #
    # @return [Boolean]
    def empty? = first.nil?

    def inspect
      "#<#{self.class.name} #{@resource_class.name} path=#{@path.inspect} per_page=#{@per_page}#{" page=#{@page}" if @page}>"
    end

    private

    # Yields each record whose id has not been yielded already. A record
    # without an id is yielded, there being nothing to tell it by.
    def each_distinct
      seen = {}
      each do |record|
        id = record.id
        next if !id.nil? && seen.key?(id)

        seen[id] = true if !id.nil?
        yield record
      end
    end

    # Whether a read of this many records is worth sizing the request for.
    #
    # Not where this collection is already limited to a page, whose size says
    # which records it holds, and not where the count is larger than the
    # endpoint serves - {#clamp_per_page} would reduce it to the same size the
    # collection already has. A zero or negative count is left to
    # Enumerable#first, which has its own answers for both.
    def own_request_for_first?(count)
      return false if @page

      count.is_a?(Integer) && count.positive? && count <= @max_per_page
    end

    def find_by_id_message(id)
      "find on a #{self.class.name} is Enumerable#find, which takes a block: #{id.inspect} would be read as its " \
        'ifnone argument and answered with an Enumerator, without a request. ' \
        "Look a record up by id on the resource itself - #{resource_reader}.find(#{id.inspect}) - " \
        'or pick one out of the records this collection holds with detect { ... }.'
    end

    # How a caller reaches this resource from a client:
    # ZammadAPI::Resources::TicketArticle is client.ticket_articles, and a
    # resource class the caller declared is client.resource(TheirClass). Looked
    # up at the moment it is needed, in an error message, so that this file
    # does not have to load the client that loads it.
    def resource_reader
      name = Client::RESOURCES.key(@resource_class)
      name ? "client.#{name}" : "client.resource(#{@resource_class.name})"
    end

    # The attributes an +order+ call names, each with its direction, in the
    # order they were written.
    #
    # @return [Hash{String => String}]
    def sort_columns(attributes, directions)
      # `order(:name, :desc)` is the spelling several other clients use, and
      # read literally it sorts by an attribute called desc - which Zammad
      # answers with a server error about an invalid column.
      misplaced = attributes.find { SORT_DIRECTIONS.include?(it.to_s.downcase) }
      raise ArgumentError, "order reads #{misplaced.inspect} as an attribute to sort by. A direction goes with its attribute: order(name: #{misplaced.to_s.downcase.to_sym.inspect})" if misplaced

      columns = {} #: Hash[String, String]
      (attributes.map { [it, 'asc'] } + directions.to_a).each do |attribute, direction|
        name = sort_attribute!(attribute)
        raise ArgumentError, "order was given #{name} twice" if columns.key?(name)

        columns[name] = sort_direction!(name, direction)
      end
      columns
    end

    def sort_attribute!(attribute)
      name = attribute.to_s
      raise ArgumentError, "order needs the name of an attribute to sort by, got #{attribute.inspect}" if (!attribute.is_a?(Symbol) && !attribute.is_a?(String)) || !SORT_ATTRIBUTE.match?(name)

      name
    end

    def sort_direction!(name, direction)
      normalized = direction.to_s.downcase
      raise ArgumentError, "order sorts #{name} either :asc or :desc, got #{direction.inspect}" if !SORT_DIRECTIONS.include?(normalized)

      normalized
    end

    # What this collection is already sorted by, read back out of the query
    # it will send.
    #
    # @return [Hash{String => String}]
    def sorted_by
      @query.fetch(:sort_by, '').to_s.split(',').zip(@query.fetch(:order_by, '').to_s.split(',')).to_h
    end

    def positive_integer!(value, name)
      raise ArgumentError, "#{name} needs a positive integer" if !value.is_a?(Integer) || !value.positive?

      value
    end

    # Re-sizing the page of a collection that {#page} already limited would
    # change which records it holds: `page(3, per_page: 50)` names records 101 to
    # 150, and re-sizing to 10 behind the caller's back served records 21 to
    # 30 instead - a different answer to the same question, with nothing said
    # about it. The two ways of naming a page cannot both be honoured, so this
    # says so rather than picking one.
    def page_size!(value, name)
      size = positive_integer!(value, name)
      raise ArgumentError, "#{name} cannot be combined with page: page(#{@page}, per_page: #{@per_page}) already named which records this collection holds. Size that page with page(#{@page}, per_page: #{size}), or slice the records with each_slice(#{size})." if @page

      size
    end

    def walk
      page      = @page || 1
      previous  = nil
      page_size = 0
      # `while`, and not `loop`. Kernel#loop rescues StopIteration, which is
      # there for an enumerator driven by hand inside it, and the block this
      # yields to is the caller's: one that calls `next` on an enumerator of
      # its own - `map { [it.id, labels.next] }` with fewer labels than
      # records - raised it from in here, and the walk took it for its own
      # end. The records and the pages after that were dropped and `map`
      # answered with what it had, where the same block over an Array raises.
      # Every way out of this loop is a `break` below.
      per_page  = @per_page
      while page
        records, digest, total = fetch(page, per_page)

        # Counted before the block has the page, not after. The Array handed
        # over is the block's to do with as it likes, and a consumer that
        # works a batch off with `shift` hands it back empty: read afterwards,
        # that was an empty page, and an import stopped after its first batch
        # with every later page still on the server.
        received = records.size

        # Before the records are handed over, not after. Yielding first meant
        # an endpoint that ignores `page` had its repeated page imported,
        # queued or written by the block, and only then did the guard that
        # exists to prevent that get to look at it.
        #
        # A digest rather than the pages themselves, because holding the
        # previous page across the next fetch doubled a walk's peak memory for
        # a guard that only ever asks whether two pages are equal. What it is
        # a digest of is in #page_digest: the ids, where every record has one.
        #
        # Where it is the payload, it is the decoded one, not the bytes it
        # arrived as. Hashing raw_body is cheaper and looks equivalent -
        # identical bytes do mean identical records - but the implication that
        # matters here runs the other way: an endpoint that ignores `page` and
        # re-serializes the same records with a different key order produces
        # different bytes every time, so the guard never fires, and because
        # every page is full the short-page break does not fire either. A
        # missed repeat is not a missed error, it is a walk that never ends.
        # `Hash#hash` ignores key order and whitespace, which is exactly the
        # insensitivity this needs - and taking it from the decoded payload
        # rather than from the built records costs nothing extra, because that
        # payload is what the records were built from one line earlier.
        #
        # An empty page is not held against the one before it. Two in a row
        # are what a search serves for two pages of hits whose records are
        # gone, with more beyond them - see #hits_past? - and there is nothing
        # on either for the block to be handed twice.
        raise PaginationError.build(operation: @operation, page: page, resource_class: @resource_class) if received.positive? && digest == previous

        yield records if received.positive?

        # A collection limited to a single page never advances.
        break if @page

        # The hits the pages read so far have covered, reckoned in the size
        # asked for. Every page this walk asks for starts where the one
        # before it ended, whatever size either was, so the last page's
        # number and size say it all.
        covered = page * per_page
        # An empty page ends the walk, unless it is a search saying that it
        # has hits beyond this one.
        break if received.zero? && !hits_past?(covered, total)

        # Every stop condition here is derived from the records the endpoint
        # actually served, and the one figure read beside them - a search's
        # total, in #hits_past? - can only keep a walk going. There was a
        # stop condition that was not: an index endpoint was believed to
        # report the size of the whole result in a header, which would have
        # ended a short walk one request earlier. Zammad sends no such header
        # from any endpoint, so it never once fired. What it did leave behind
        # was a stop condition that could end a walk early on a figure the
        # records did not corroborate, which is the one way a walk can be
        # wrong rather than merely slow.
        #
        # How big a page this endpoint actually serves, learned from the first
        # one rather than assumed. The requested size is clamped to a per-
        # resource page limit, and where that guess was higher than the
        # server's real cap - a lowered setting, a custom deployment, an
        # endpoint whose cap was never this generous - every page came back
        # short and the walk stopped on page one with a truncated result and
        # nothing to show for it.
        #
        # Asked of an index endpoint only. Its page is one SQL query with an
        # offset and a limit, so a page short of the size it has been serving
        # is the last one. A search page is put together in two steps:
        # ApplicationController#model_search_render has the search - through
        # Elasticsearch, or through SQL - name the ids for the page, and then
        # loads the records with `where(id: ids)`. An id whose record is gone
        # by the second step is left out and nothing fills its place: a ticket
        # deleted in between, or one Elasticsearch still lists because its
        # index has drifted from the database. So a search can serve 199 of
        # 200 on page two with page three still to come, and stopping there
        # truncated the result with nothing to say so. Only an empty page
        # ends a search walk, which costs one more request where the last
        # page of hits is part-filled - and not every empty page does, for
        # the same reason: see #hits_past?.
        page_size = received if page_size.zero?
        break if !@search && received < page_size

        previous = digest
        page, per_page = page_after(page, per_page, received, total)
      end
    end

    # The page that follows one a walk has read, and its size: the next of
    # the same size, except past an empty page in a read sized by {#first},
    # which asks for more at a time from there. Only a search gets this far
    # with nothing received.
    #
    # @return [Array(Integer, Integer)] the page to ask for and its size
    def page_after(page, per_page, received, total)
      received.zero? && @widens ? widened(page * per_page, total) : [page + 1, per_page]
    end

    # The page to ask for after an empty one, in a read that may widen: the
    # largest the endpoint serves that starts exactly where the pages read so
    # far ended.
    #
    # {#first} and {#empty?} size their request to the records they want,
    # and a search is read on past a page with nothing on it while the total
    # says there are hits behind it. Kept at that size, the two together
    # cost a request for every stale hit: on an instance whose Elasticsearch
    # index has drifted from its database - one restored without a reindex -
    # `search(term).empty?` behind five thousand of them made five thousand
    # requests, one after the other, before it answered.
    #
    # The size that was asked for stopped being the right one at the first
    # empty page: it was chosen to fetch no more than was wanted, and what it
    # fetched was nothing. But a larger page cannot simply be asked for from
    # there. A page is a position - page 3 of 50 is hits 101 to 150 - so one
    # of another size starts somewhere else, and a read that moved to it
    # would pass over hits or be handed records a second time.
    #
    # So the next page is one whose size divides what has been covered,
    # which makes its start fall exactly on the end of the last: with 8 hits
    # covered, page 2 of 8 is hits 9 to 16. The size doubles that way from a
    # page of one, and from the endpoint's own limit on it is the largest
    # divisor that fits. Five thousand stale hits are read past in
    # thirty-four requests.
    #
    # No page reaches past the total the search last reported, though the
    # endpoint would serve one: with 256 hits covered of 300, the next page
    # is 32 hits rather than 128. Zammad hands the offset and the size to
    # Elasticsearch as they are, and an index whose result window was
    # lowered below them - the per-model settings allow it - refuses the
    # request, which Zammad answers as no hits and a total of nought. Asked
    # for hits 257 to 384 against a window of 300, a read with a live hit
    # at 280 answered nil where a page of one would have found it. The
    # window cannot be seen from here, so a total beyond it still leaves the
    # read to end there; the default window is a million hits.
    #
    # It takes the endpoint to serve the size it is asked for, up to
    # +max_per_page+, which is what #hits_past? takes as well. One that
    # serves less pages by its own size, so page 3 of 192 served as 100 is
    # hits 201 to 300: hits are passed over, and the pages read cover less
    # than the walk takes them to. A hit served twice is left out by
    # {#first}. A page of one, which every endpoint serves, could not go
    # wrong that way. Zammad serves a search the 200 this asks for at most,
    # so it takes an instance whose cap was lowered, and the README says so
    # beside the walk's own limits.
    #
    # Not for a size a caller chose. `in_batches(of: 10)` says how many
    # records a batch may hold, and a page of 160 is not one of those.
    #
    # @param covered [Integer] the hits the pages read so far have covered
    # @param total [Integer, nil] the hits the search last reported
    # @return [Array(Integer, Integer)] the page to ask for and its size
    def widened(covered, total)
      limit = total ? (total - covered).clamp(1, @max_per_page) : @max_per_page
      pages = covered.fdiv(limit).ceil
      pages += 1 until (covered % pages).zero?

      [pages + 1, covered / pages]
    end

    def with(page: @page, per_page: @per_page, query: @query, widens: false)
      self.class.new(
        transport:       @transport,
        resource_class:  @resource_class,
        path:            @path,
        operation:       @operation,
        max_per_page:    @max_per_page,
        sortable:        @sortable,
        unsortable_hint: @unsortable_hint,
        query:           query,
        per_page:        per_page,
        page:            page,
        search:          @search,
        widens:          widens
      )
    end

    # Whether a search reports hits beyond the page just read, which is what
    # tells a page with nothing on it from the end of the result.
    #
    # A search page can come back empty with hits still to come, for the
    # reason it can come back short: every id the search named for it has
    # lost its record. On a page of 200 that takes 200 stale hits in a row.
    # On the page of one that {#first} and {#empty?} ask for it takes one,
    # and a search sorts by `updated_at`, newest first - so the hit likeliest
    # to be stale, a record deleted a moment ago that Elasticsearch has yet
    # to drop, is the first one served. `search(term).first` answered nil and
    # `empty?` true for a search with live hits right behind it, and `each`
    # ended on such a page with the rest unread.
    #
    # So a search that is walked asks for the size of the whole result beside
    # every page - see #page_query - and an empty page ends the walk only
    # once the pages read have covered it.
    #
    # The figure is not used the other way round, to end a walk on a page
    # that still held records and save the request after it. Elasticsearch
    # stops counting at ten thousand hits and reports that as the total, so
    # a walk ended on the figure would stop there with the rest unread -
    # which is the stop condition the note in #walk is about. Past that
    # figure an empty page ends the walk, as it does where there is no figure
    # at all: a Zammad before 6.5.1 answers `with_total_count` under `expand`
    # with the bare array. That is the gap this leaves.
    #
    # Reckoned in the page sizes that were asked for. An endpoint that pages
    # smaller has covered fewer hits than this takes it to have, and the
    # walk then ends on an empty page it might have read past - no earlier
    # than it ended before the figure was read at all.
    #
    # What reading on costs is bounded by the same figure: a request per
    # page of the hits the endpoint reports, and none beyond them. How large
    # those pages are is what #widened is about.
    #
    # @param covered [Integer] the hits the pages read so far have covered
    def hits_past?(covered, total) = !total.nil? && covered < total

    # Fetches one page: the records, the digest the repeated-page guard
    # compares, and the size of the whole result where the endpoint reported
    # it beside them.
    #
    # @return [Array(Array<Resources::Base>, Integer, Integer)] the records,
    #   the digest and the total
    # @return [Array(Array<Resources::Base>, Integer, nil)] where no total
    #   was reported
    def fetch(page, per_page)
      response = @transport.get(
        @path,
        operation:      @operation,
        resource_class: @resource_class,
        query:          page_query(page, per_page)
      )
      decoded, total = response.decoded_list(operation: @operation, resource_class: @resource_class)
      # The digest for the repeated-page guard is taken here, from the decoded
      # payload, which is the one structure that has everything the guard needs
      # and is already in hand. See the guard in `walk` for why it is this and
      # not the records or the raw body.
      [decoded.map { @resource_class.from_response(@transport, it) }, page_digest(decoded), total]
    end

    # The parameters of a request for one page.
    #
    # `with_total_count` goes out where the answer is read, which is a search
    # being walked: see #hits_past?. An index drops the parameter along with
    # everything else it does not know, and a collection limited to one page
    # has no walk to end, so both are sent what they always were.
    #
    # It costs Zammad nothing it was not doing. model_search_render asks the
    # search for the total on every request and leaves it out of the answer
    # unless the parameter is there.
    def page_query(page, per_page)
      query = @query.merge(page: page, per_page: per_page)

      @search && @page.nil? ? query.merge(with_total_count: true) : query
    end

    # What the repeated-page guard compares two pages by: which records they
    # hold, where every record says which it is.
    #
    # The whole payload was the first answer, and it misses the repeat that
    # matters most. A job that writes to the records it is handed changes
    # what they serialize as - `updated_at`, if nothing else - so an endpoint
    # that ignores `page` served the same records with a different payload
    # every time. No two pages compared equal, every page was full, and the
    # job went round the same records, writing to each of them again, for as
    # long as it was left running.
    #
    # The ids as a set rather than as a list, because a write can reorder
    # them too: a search sorts by `updated_at` unless told otherwise.
    #
    # The payload is still what is compared where a record carries no id.
    # Compared by id, a page of those is a list of nils equal to every other
    # such page, and a perfectly good paginator was reported as stuck.
    #
    # @return [Integer]
    def page_digest(decoded)
      ids = decoded.map { it[:id] }

      ids.include?(nil) ? decoded.hash : ids.to_set.hash
    end

    # Asked only of a search endpoint, which is the only kind that answers
    # +only_total_count+. Every one of them routes through
    # model_search_render, which reads it before it reads anything else, so a
    # shape other than the +{total_count: n}+ object means something has
    # answered that is not the endpoint this was addressed to - a proxy error
    # page, a login form - and the walk is the honest fallback.
    #
    # A negative figure is refused rather than trusted: it cannot describe a
    # result, and a count is the one answer nothing downstream can sanity
    # check - `Array.new(collection.count)` and `count.zero?` both take it at
    # its word.
    #
    # @return [Integer, nil] nil when the endpoint did not report a total
    def total_count
      response = @transport.get(
        @path,
        operation:      @operation,
        resource_class: @resource_class,
        query:          @query.merge(only_total_count: true)
      )
      return nil if !response.body.is_a?(Hash)

      total = response.body[:total_count]
      total if total.is_a?(Integer) && !total.negative?
    end

    # Reduced rather than refused, unlike the size {#page} takes. The
    # asymmetry is deliberate: a batch size says how much to fetch at a time,
    # so a smaller one costs more requests and still walks to the same last
    # record, while {#page}'s size also decides which records the page holds,
    # and reducing that answers a different question than the one asked.
    #
    # It is also what lets one batch size be written against resources that
    # cap differently - the index endpoints allow 1000, tickets 100, a search
    # 200 - without the caller looking each of them up.
    def clamp_per_page(size)
      raise ArgumentError, 'per_page needs to be a positive integer' if !size.is_a?(Integer) || !size.positive?

      [size, @max_per_page].min
    end
  end
end
