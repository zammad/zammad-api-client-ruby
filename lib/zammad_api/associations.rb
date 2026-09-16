# frozen_string_literal: true

require_relative 'errors'
require_relative 'transport'

module ZammadAPI
  # Readers for the records a record points at.
  module Associations
    # Fetches the records an association points at.
    #
    # Reached through +record.related+, never built directly. The readers live
    # here rather than on the record itself because Zammad already expands an
    # association into a name: +ticket.customer+ is the customer's login and
    # +ticket.state+ is +"open"+, both free of charge. An association reader
    # returns the whole record and costs a request, so it is worth telling the
    # two apart at the call site.
    #
    # @example
    #   ticket = client.ticket.find(1)
    #
    #   ticket.customer               # => "customer@example.com", already loaded
    #   ticket.related.customer       # => the User record, one request
    #   ticket.related.customer.email # => "customer@example.com"
    #
    #   ticket.related.articles       # => [TicketArticle, ...]
    class Proxy
      # @api private
      # @param record [Resources::Base]
      def initialize(record)
        @record = record
        @cache  = {}
      end

      def inspect
        "#<#{Proxy.name} #{@record.class.name} id=#{@record.id.inspect} #{@record.class.associations.keys.join(', ')}>"
      end

      private

      # Memoized: the record an id points at does not change under the caller,
      # and an unmemoized reader would turn a loop over tickets into a request
      # per ticket per mention. {Resources::Base#reload} drops the memo.
      def belongs_to_target(name, class_name, foreign_key)
        return @cache[name] if @cache.key?(name)

        id = @record[foreign_key]
        # {Resources::Base.fetch_one} rather than a ResourceProxy built for the
        # one call: {Client#setup} builds and freezes one proxy per resource so
        # that callers get one proxy per resource, and a reader here that built
        # a fresh one per association turned a walk over ten thousand tickets
        # reading two associations each into twenty thousand objects that exist
        # for a single method call. It is the read {ResourceProxy#find} makes
        # too, so there is one of it rather than one here and one there.
        @cache[name] = id.nil? ? nil : resolve(class_name).fetch_one(@record.transport, id)
      end

      # Deliberately not memoized: a list can grow while the record is held,
      # and +ticket.related.articles+ after +ticket.article(...)+ has to show
      # the article that was just added.
      #
      # The path proc is handed the escaped id rather than the record, so that
      # a declaration cannot paste a raw id into a path. One that did resolved
      # `related.articles` on a record carrying `id: "1/../../users"` onto the
      # users endpoint, the same way an unescaped {Resources::Base#member_path}
      # used to - and a proc is exactly where that is easy to forget.
      def has_many_target(name, class_name, path)
        raise Error, "#{@record.class.name} has no id, so it has no #{name} to read; save it first" if @record.id.nil?

        target_class = resolve(class_name)
        operation    = "get #{name}"

        response = @record.transport.get(
          path.call(Transport.escape_path_segment(@record.id)),
          operation:      operation,
          resource_class: target_class,
          query:          { expand: true }
        )
        records = response.decoded(:array, operation: operation, resource_class: target_class)
        refuse_partial_list!(response, records.size, operation, target_class)
        records.map { target_class.from_response(@record.transport, it) }
      end

      # A has_many reader spends one request and hands back the whole list,
      # because the endpoints these are declared against serve it whole -
      # +by_ticket+ answers with every article a ticket has. It is the one
      # list in the gem that does not walk, and that is a property of the
      # endpoint rather than of the declaration: a target that started paging
      # would have handed back its first page and nothing to say so, while
      # +all+ and +search+ walk to the end.
      #
      # Index endpoints report the size of the whole result in a header, so
      # that is worth checking rather than trusting. Saying so costs nothing
      # and turns a silently short list into a failure that names itself.
      def refuse_partial_list!(response, served, operation, target_class)
        total = response.reported_total
        return if total.nil? || served >= total

        raise PaginationError.truncated(operation: operation, served: served, total: total, resource_class: target_class)
      end

      # The target is named rather than referenced so that resources may point
      # at each other without a load order between their files. The name comes
      # from a declaration in this gem, never from a caller.
      def resolve(class_name) = Resources.const_get(class_name, false)
    end
  end
end
