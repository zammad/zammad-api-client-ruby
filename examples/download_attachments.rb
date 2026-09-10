#!/usr/bin/env ruby
# frozen_string_literal: true

# Downloads every attachment of a ticket to a directory.
#
# Demonstrates: walking articles, attachment metadata, and binary-safe
# downloads.
#
#   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=... \
#     ruby examples/download_attachments.rb 12345 ./downloads

require 'zammad_api'
require 'fileutils'

client = ZammadAPI::Client.from_env

ticket_id = Integer(ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} TICKET_ID [DIRECTORY]" })
directory = ARGV.fetch(1, "ticket-#{ticket_id}")

ticket = client.ticket.find(ticket_id)
FileUtils.mkdir_p(directory)

# The filename comes from the server, so it is not trusted to be a plain
# basename: `File.basename` strips any directory part that would otherwise
# let `../` escape the download directory. The attachment id keeps two
# same-named attachments on one article from overwriting each other.
def safe_filename(article_id, attachment)
  name = File.basename(attachment.filename.to_s)
  name = 'attachment' if name.empty? || name.start_with?('.')
  "#{article_id}-#{attachment.id}-#{name}"
end

saved = 0
ticket.articles.each do |article|
  article.attachments.each do |attachment|
    # `download` returns the bytes in ASCII-8BIT, so images and archives
    # survive intact.
    contents = attachment.download
    path     = File.join(directory, safe_filename(article.id, attachment))

    File.binwrite(path, contents)
    saved += 1

    puts format(
      '%<file>-40s %<size>8d bytes  %<type>s',
      file: attachment.filename,
      size: contents.bytesize,
      type: attachment.preferences&.dig(:'Mime-Type') || 'unknown'
    )
  end
end

puts saved.zero? ? "Ticket ##{ticket.number} has no attachments." : "Saved #{saved} file(s) to #{directory}/"
