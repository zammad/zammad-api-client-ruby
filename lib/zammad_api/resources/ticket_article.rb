# frozen_string_literal: true

require_relative '../errors'
require_relative 'base'
require_relative 'ticket_article_attachment'

module ZammadAPI
  module Resources
    class TicketArticle < Base
      path 'api/v1/ticket_articles'

      # Named the way a has_many reader names its own read - `get articles` -
      # so the refusal below reads like every other one this gem raises.
      ATTACHMENTS_OPERATION = 'get attachments'
      private_constant :ATTACHMENTS_OPERATION

      belongs_to :ticket, class_name: 'Ticket'

      # @return [Array<TicketArticleAttachment>] the article's attachments
      # @raise [ParseError] when the article does not carry attachment
      #   metadata in the shape Zammad serves
      def attachments
        list = attributes[:attachments] || []
        # The same check {Response#decoded} makes on a list of records, for
        # the same reason: this metadata comes off a response body, and an
        # element that is not an object reached `raw.merge` and died there as
        # `undefined method 'merge' for an instance of String` - a bare
        # NoMethodError from inside the gem, past the `rescue ZammadAPI::Error`
        # every caller is told to write, for a body that was simply not what
        # it claimed to be.
        raise ParseError.build(operation: ATTACHMENTS_OPERATION, expected: 'array of objects', actual: list.class, resource_class: self.class) if !list.is_a?(Array)

        list.map { attachment(it) }
      end

      private

      def attachment(raw)
        raise ParseError.build(operation: ATTACHMENTS_OPERATION, expected: 'array of objects', actual: "an array holding #{raw.class}", resource_class: self.class) if !raw.is_a?(Hash)

        TicketArticleAttachment.new(
          transport,
          raw.merge(ticket_id: attributes[:ticket_id], article_id: id)
        )
      end
    end
  end
end
