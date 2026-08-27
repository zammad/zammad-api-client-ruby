# frozen_string_literal: true

require_relative '../attribute_access'
require_relative '../errors'

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
        @attributes = deep_symbolize(attributes || {})
      end

      # Downloads the attachment.
      #
      # @return [String] the file contents, in +ASCII-8BIT+ encoding
      # @raise [ResponseError] when Zammad rejected the request
      def download
        response = @transport.get(
          "api/v1/ticket_attachment/#{fetch(:ticket_id)}/#{fetch(:article_id)}/#{fetch(:id)}",
          operation:      'download attachment',
          resource_class: self.class
        )
        # Attachments are arbitrary binary data; the transport's charset
        # guess must not corrupt them.
        response.raw_body.dup.force_encoding(Encoding::BINARY)
      end

      def inspect
        "#<#{self.class.name} id=#{id.inspect} filename=#{self[:filename].inspect} size=#{self[:size].inspect}>"
      end
    end
  end
end
