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
    # @param countable [Boolean] whether this endpoint answers
    #   +only_total_count+, which only a search endpoint does
    # @param sortable [Boolean] whether this endpoint reads +sort_by+ and
    #   +order_by+
    # @param unsortable_hint [String] what to do instead where it does not
    def initialize(transport:, resource_class:, path:, operation:, max_per_page:, sortable:, unsortable_hint:, query: {}, per_page: nil, page: nil, countable: false)
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
      @countable       = countable
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
    # @param count [Integer, nil] how many records to read
    # @return [Resources::Base, Array<Resources::Base>, nil] one record, or an
    #   array of them when +count+ was given
    def first(count = nil)
      wanted = count || 1
      sized  = own_request_for_first?(wanted) ? with(per_page: wanted) : self
      # Through the enumerator rather than `super`, so that the sized
      # collection does the reading and this method is not asked to be both
      # the caller and the callee of Enumerable#first.
      count.nil? ? sized.each.first : sized.each.first(count)
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
      return super if !args.empty? || block || @page || !@countable

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
    # records that page holds and so cannot be narrowed.
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
        "Look a record up by id on the resource itself - client.#{resource_name}.find(#{id.inspect}) - " \
        'or pick one out of the records this collection holds with detect { ... }.'
    end

    # The resource as a client names it: ZammadAPI::Resources::TicketArticle
    # is reached as client.ticket_articles. Derived rather than looked up in
    # {Client::RESOURCES}, because a resource a caller subclasses themselves is
    # in no list, and this is a sentence in an error message either way. From
    # the path rather than the class name, because the path is already the
    # plural Zammad itself uses: a class name would need "priority" turned
    # into "priorities" by a rule this gem has no other use for.
    def resource_name = @resource_class.resource_path.split('/').last.to_s

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
      loop do
        records, digest = fetch(page, @per_page)

        # Before the records are handed over, not after. Yielding first meant
        # an endpoint that ignores `page` had its repeated page imported,
        # queued or written by the block, and only then did the guard that
        # exists to prevent that get to look at it.
        #
        # Whole payloads rather than ids: an endpoint that serves records
        # without an id would compare two empty lists on every page and so
        # report a perfectly good paginator as stuck. A digest rather than the
        # payloads themselves, because holding the previous page across the
        # next fetch doubled a walk's peak memory for a guard that only ever
        # asks whether two pages are equal.
        #
        # The decoded payload, not the bytes it arrived as. Hashing raw_body
        # is cheaper and looks equivalent - identical bytes do mean identical
        # records - but the implication that matters here runs the other way:
        # an endpoint that ignores `page` and re-serializes the same records
        # with a different key order produces different bytes every time, so
        # the guard never fires, and because every page is full the short-page
        # break does not fire either. A missed repeat is not a missed error,
        # it is a walk that never ends. `Hash#hash`
        # ignores key order and whitespace, which is exactly the insensitivity
        # this needs - and taking it from the decoded payload rather than from
        # the built records costs nothing extra, because that payload is what
        # the records were built from one line earlier.
        raise PaginationError.build(operation: @operation, page: page, resource_class: @resource_class) if digest == previous

        yield records if !records.empty?

        # A collection limited to a single page never advances.
        break if @page
        break if records.empty?

        # Every stop condition here is derived from the records the endpoint
        # actually served. There was one that was not - an index endpoint was
        # believed to report the size of the whole result in a header, which
        # would have ended a short walk one request earlier - and Zammad sends
        # no such header from any endpoint, so it never once fired. What it
        # did leave behind was a stop condition that could end a walk early on
        # a figure the records did not corroborate, which is the one way a
        # walk can be wrong rather than merely slow.
        #
        # How big a page this endpoint actually serves, learned from the first
        # one rather than assumed. The requested size is clamped to a per-
        # resource page limit, and where that guess was higher than the
        # server's real cap - a lowered setting, a custom deployment, an
        # endpoint whose cap was never this generous - every page came back
        # short and the walk stopped on page one with a truncated result and
        # nothing to show for it.
        page_size = records.size if page_size.zero?
        break if records.size < page_size

        previous = digest
        page += 1
      end
    end

    def with(page: @page, per_page: @per_page, query: @query)
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
        countable:       @countable
      )
    end

    # Fetches one page and the digest the repeated-page guard compares.
    #
    # @return [Array(Array<Resources::Base>, Integer)] the records and the
    #   digest
    def fetch(page, per_page)
      response = @transport.get(
        @path,
        operation:      @operation,
        resource_class: @resource_class,
        query:          @query.merge(page: page, per_page: per_page)
      )
      decoded = response.decoded(:array, operation: @operation, resource_class: @resource_class)
      # The digest for the repeated-page guard is taken here, from the decoded
      # payload, which is the one structure that has everything the guard needs
      # and is already in hand. See the guard in `walk` for why it is this and
      # not the records or the raw body.
      [decoded.map { @resource_class.from_response(@transport, it) }, decoded.hash]
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
