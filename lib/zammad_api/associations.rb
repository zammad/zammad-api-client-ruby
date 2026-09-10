# frozen_string_literal: true

require_relative 'errors'
require_relative 'resource_proxy'

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
        @cache[name] = id.nil? ? nil : ResourceProxy.new(@record.transport, resolve(class_name)).find(id)
      end

      # Deliberately not memoized: a list can grow while the record is held,
      # and +ticket.related.articles+ after +ticket.article(...)+ has to show
      # the article that was just added.
      def has_many_target(name, class_name, path)
        target_class = resolve(class_name)
        operation    = "get #{name}"

        response = @record.transport.get(
          path.call(@record),
          operation:      operation,
          resource_class: target_class,
          query:          { expand: true }
        )
        response
          .decoded(:array, operation: operation, resource_class: target_class)
          .map { target_class.from_response(@record.transport, it) }
      end

      # The target is named rather than referenced so that resources may point
      # at each other without a load order between their files. The name comes
      # from a declaration in this gem, never from a caller.
      def resolve(class_name) = Resources.const_get(class_name, false)
    end
  end
end
