# frozen_string_literal: true

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
    class Proxy
      # @api private
      # @param record [Resources::Base]
      def initialize(record)
        @record = record
        @cache  = {}
      end

      def inspect
        "#<#{Proxy.name} #{@record.class.name} id=#{@record.id.inspect} #{associations.keys.join(', ')}>"
      end

      # Drops the records read so far, so the next read follows the record's
      # current foreign keys.
      #
      # @api private
      # @return [void]
      def forget
        @cache = {}
      end

      def method_missing(name, *args)
        spec = associations[name]
        return super if spec.nil? || !args.empty?

        target(name, spec)
      end

      def respond_to_missing?(name, include_private = false) = associations.key?(name) || super

      private

      def associations = @record.class.associations

      # The record a foreign key points at, read once and kept: nil when the
      # key is nil.
      def target(name, spec)
        return @cache[name] if @cache.key?(name)

        id = @record[spec[:foreign_key]]
        @cache[name] = id.nil? ? nil : resolve(spec[:class_name]).fetch_one(@record.transport, id)
      end

      # A resource of this gem by its own name, or any class by its full name.
      def resolve(class_name)
        return Resources.const_get(class_name, false) if Resources.const_defined?(class_name, false)

        Object.const_get(class_name)
      end
    end
  end
end
