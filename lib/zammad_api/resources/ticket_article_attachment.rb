# frozen_string_literal: true

require_relative '../attribute_access'
require_relative '../errors'
require_relative '../transport'

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
        @attributes = frozen_attributes(attributes || {})
      end

      # Asks for the file as it is stored. A response says how long it is in
      # the bytes that were sent, and the transport can hold that against
      # the bytes in hand only where nothing decoded them on the way: see
      # {Transport.missing_bytes}. Left to itself Net::HTTP asks for gzip
      # and inflates what arrives, without a word for a stream that stops
      # halfway, so a text attachment behind a proxy that compresses came
      # back as its first part when the connection was closed under it.
      UNENCODED = { 'Accept-Encoding' => 'identity' }.freeze
      private_constant :UNENCODED

      # Downloads the attachment.
      #
      # The file is asked for with +Accept-Encoding: identity+, so that one
      # the connection was closed under is told from a whole one.
      #
      # @return [String] the file contents, in +ASCII-8BIT+ encoding
      # @raise [ResponseError] when Zammad rejected the request
      # @raise [IncompleteResponseError] when the connection was closed before the
      #   whole file had arrived. The part that did arrive is not returned.
      def download
        response = request_file(UNENCODED)
        # A server that encodes the body all the same has sent what only
        # the adapter reads, and an adapter handed the header leaves that
        # to its caller: the bytes would be the compressed ones. Asked
        # again the way every other request is, the file is decoded as it
        # was before, and its length goes unchecked as it did before.
        response = request_file(nil) if response.headers.key?('content-encoding')
        # Attachments are arbitrary binary data; the transport's charset
        # guess must not corrupt them.
        response.raw_body.dup.force_encoding(Encoding::BINARY)
      end

      def inspect
        "#<#{self.class.name} id=#{id.inspect} filename=#{self[:filename].inspect} size=#{self[:size].inspect}>"
      end

      protected

      # @see AttributeAccess#installation
      def installation = @transport.config.url

      private

      def request_file(headers)
        segments = %i[ticket_id article_id id].map { Transport.escape_path_segment(fetch(it)) }

        @transport.get(
          "api/v1/ticket_attachment/#{segments.join('/')}",
          operation:      'download attachment',
          headers:        headers,
          resource_class: self.class
        )
      end
    end
  end
end
