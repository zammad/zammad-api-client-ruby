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
    #   ticket = client.tickets.find(1)
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
      # per ticket per mention. The record empties the memo through
      # {#forget_targets} when what it was resolved from may no longer hold.
      def belongs_to_target(name, class_name, foreign_key)
        refuse_destroyed!(name)
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
      # and +ticket.related.articles+ after +ticket.add_article(...)+ has to show
      # the article that was just added.
      #
      # The path proc is handed the escaped id rather than the record, so that
      # a declaration cannot paste a raw id into a path. One that did resolved
      # `related.articles` on a record carrying `id: "1/../../users"` onto the
      # users endpoint, the same way an unescaped {Resources::Base#member_path}
      # used to - and a proc is exactly where that is easy to forget.
      def has_many_target(name, class_name, path)
        refuse_destroyed!(name)
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
        records.map { target_class.from_response(@record.transport, it) }
      end

      # Drops every resolved target, so that the next read fetches it again.
      #
      # Called by the record, which keeps one proxy for as long as it lives
      # and empties it on a save, a reload, a destroy and a write to a foreign
      # key. It used to drop the proxy and build another on the next call to
      # {Resources::Base#related}, which reached only the callers that asked
      # again: `related = ticket.related`, the natural thing to write before
      # reading two associations, kept the proxy that had been dropped, and
      # after `ticket.customer_id = 9` or a reload `related.customer` went on
      # answering with the user it had resolved before. A memo can only be
      # emptied where it is held, so it is emptied here.
      def forget_targets
        @cache.clear
      end

      # Refuses to read through a record that was destroyed.
      #
      # {Resources::Base#related} asks the same question, but a proxy handed
      # out before the destroy is already past that door: it answered from
      # its memo, and `articles` requested the articles of a ticket that is
      # gone.
      def refuse_destroyed!(name)
        return if !@record.destroyed?

        raise Error, "#{@record.class.name} #{@record.id} was destroyed, there is nothing to read #{name} from"
      end

      # The target is named rather than referenced so that resources may point
      # at each other without a load order between their files. The name comes
      # from a declaration in code - this gem's, or a resource class a caller
      # wrote - and never from data.
      #
      # A resource of this gem is named on its own, +'User'+, and wins: an
      # application is likely to have a +User+ of its own at the top level,
      # and that is not what a ticket's customer is. Any other name is read
      # from the top level, so that a resource a caller declares can point at
      # another of theirs: +belongs_to :role, class_name: 'Acme::Role'+.
      def resolve(class_name)
        return Resources.const_get(class_name, false) if Resources.const_defined?(class_name, false)

        Object.const_get(class_name)
      end
    end
  end
end
