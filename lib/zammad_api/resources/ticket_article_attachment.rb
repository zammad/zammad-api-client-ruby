# frozen_string_literal: true

module ZammadAPI
  module Resources
    # An attachment of a ticket article.
    #
    # Attachments are read-only metadata until {#download} is called, which
    # returns the file contents.
    class TicketArticleAttachment
      include AttributeAccess

      # @api private
      # @param transport [Transport]
      # @param attributes [Hash]
      def initialize(transport, attributes = {})
        @transport  = transport
        @attributes = frozen_attributes(Hash(attributes)) # steep:ignore UnresolvedOverloading
      end

      # Downloads the attachment.
      #
      # @return [String] the file contents, in +ASCII-8BIT+ encoding
      # @raise [ResponseError] when Zammad rejected the request
      def download
        segments = %i[ticket_id article_id id].map { Transport.escape_path_segment(fetch(it)) }
        response = @transport.get(
          "api/v1/ticket_attachment/#{segments.join('/')}",
          operation:      'download attachment',
          resource_class: self.class
        )

        response.raw_body.b
      end

      def inspect
        "#<#{self.class.name} id=#{id.inspect} filename=#{self[:filename].inspect} size=#{self[:size].inspect}>"
      end
    end
  end
end
