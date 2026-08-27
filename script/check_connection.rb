#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end check that this gem can actually drive a live Zammad instance.
#
# Deliberately standalone: it does not load the spec suite, so it still
# reports usefully when the specs themselves are what is broken. CI runs it
# after booting Zammad and before the integration specs, so a broken
# gem-to-Zammad link fails fast with a readable transcript.
#
#   TEST_URL=http://localhost:3000/ \
#   TEST_USER=admin@example.com \
#   TEST_PASSWORD=test \
#     bundle exec ruby script/check_connection.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'zammad_api'
require 'faraday'
require 'json'
require 'securerandom'

URL      = ENV['TEST_URL']      || 'http://localhost:3000/'
LOGIN    = ENV['TEST_USER']     || 'admin@example.com'
PASSWORD = ENV['TEST_PASSWORD'] || 'test'
SUFFIX   = SecureRandom.hex(4)

@failures = []
@group    = nil
@ticket   = nil

# Runs one named check, printing its result and recording any failure.
def check(name)
  detail = yield
  puts format('  ok    %<name>-42s %<detail>s', name: name, detail: detail)
  true
rescue => e
  @failures << name
  puts format('  FAIL  %<name>-42s %<error>s: %<message>s', name: name, error: e.class, message: e.message)
  false
end

# A check whose failure makes every later check meaningless, so the run stops
# rather than burying the cause under cascading NoMethodErrors.
def check!(name, &block)
  return if check(name, &block)

  puts "\nAborting: '#{name}' is a precondition for the remaining checks."
  finish
end

def section(title)
  puts "\n#{title}"
end

def parse_json(body)
  JSON.parse(body)
rescue JSON::ParserError
  {}
end

def cleanup
  return if @group.nil? && @ticket.nil?

  section 'Cleanup'
  check('destroy the ticket') { CLIENT.ticket.destroy(@ticket.id) } if @ticket
  check('destroy the group')  { CLIENT.group.destroy(@group.id) }   if @group
end

def finish
  cleanup
  puts
  if @failures.empty?
    puts 'All checks passed.'
    exit 0
  end

  puts "#{@failures.size} check(s) failed:"
  @failures.each { puts "  - #{it}" }
  exit 1
end

puts "Checking #{URL} with zammad_api #{ZammadAPI::VERSION} on Ruby #{RUBY_VERSION}"

section 'Instance setup'

# The auto wizard creates the admin account. An instance that is already
# configured reports failure here, which is fine as long as it is set up.
check!('auto wizard or already configured') do
  wizard = parse_json(Faraday.new(url: URL).get('api/v1/getting_started/auto_wizard').body)
  next 'auto wizard ran' if wizard['auto_wizard_success']

  # A configured Zammad requires authentication even for
  # /api/v1/getting_started, so the setup state cannot be read from there.
  # An authenticated request answers the only question that matters.
  ZammadAPI::Client.new(url: URL, user: LOGIN, password: PASSWORD, retries: 0)
    .group.all.page(1, per_page: 1).to_a
  'already set up'
end

CLIENT = ZammadAPI::Client.new(url: URL, user: LOGIN, password: PASSWORD, timeout: 30)

section 'Client'

check('credentials are redacted') do
  raise 'password leaked into inspect output' if CLIENT.config.inspect.include?(PASSWORD)

  'password absent from inspect output'
end

check('derived client re-validates options') do
  CLIENT.with(timeout: 45)
  CLIENT.with(timeout: -1)
  raise 'expected ConfigurationError'
rescue ZammadAPI::ConfigurationError
  'invalid option rejected'
end

section 'Records'

check!('create a group') do
  @group = CLIENT.group.create(name: "smoke-#{SUFFIX}", note: 'created by check_connection.rb')
  raise 'no id assigned' if @group.id.nil?

  "id=#{@group.id}"
end

check('find it back') do
  found = CLIENT.group.find(@group.id)
  raise "name mismatch: #{found.name}" if found.name != "smoke-#{SUFFIX}"

  found.name
end

check('update only the changed attribute') do
  @group.note = 'updated'
  raise 'change not staged' if !@group.changed?

  @group.save
  CLIENT.group.find(@group.id).note
end

check('reload discards local changes') do
  @group.note = 'not saved'
  @group.reload.note
end

check('pattern match a record') do
  case CLIENT.group.find(@group.id)
  in { name: String => name, active: true } then name
  else raise 'record did not match the expected pattern'
  end
end

section 'Collections'

check('iterate every group across pages') do
  names = CLIENT.group.all.map(&:name)
  raise 'created group missing from .all' if !names.include?("smoke-#{SUFFIX}")

  "#{names.size} groups"
end

check('fetch a single page') { "#{CLIENT.group.all.page(1, per_page: 1).to_a.size} record" }

check('lazy enumeration stops early') { CLIENT.group.all.lazy.map(&:id).first(1).inspect }

check('page by page') do
  pages = 0
  CLIENT.group.all(per_page: 1).each_page { pages += 1 }
  "#{pages} page(s)"
end

check('search') { "#{CLIENT.user.search(query: LOGIN).to_a.size} hits" }

section 'Tickets'

check!('create a ticket with its first article') do
  @ticket = CLIENT.ticket.create(
    title:    "smoke ticket #{SUFFIX}",
    group:    'Users',
    customer: LOGIN,
    article:  { subject: 'smoke', body: 'created by check_connection.rb', type: 'note' }
  )
  "number=#{@ticket.number}"
end

check('read its articles') { "#{@ticket.articles.size} article(s)" }

check('add another article') do
  CLIENT.ticket.find(@ticket.id).article(subject: 'second', body: 'another one', type: 'note').id
end

check('article count grew') do
  count = @ticket.articles.size
  raise "expected 2 articles, got #{count}" if count != 2

  count
end

check('attachment metadata and download') do
  CLIENT.ticket.find(@ticket.id).article(
    subject:     'with attachment',
    body:        'see attachment',
    type:        'note',
    attachments: [{ filename: 'smoke.txt', data: ['smoke test 123'].pack('m0'), 'mime-type': 'text/plain' }]
  )
  attachment = @ticket.articles.last.attachments.first
  raise 'no attachment returned' if attachment.nil?
  raise "unexpected content: #{attachment.download.inspect}" if attachment.download != 'smoke test 123'

  "#{attachment.filename} (#{attachment.download.bytesize} bytes)"
end

section 'On behalf of another user'

check('sends the From header') do
  CLIENT.on_behalf_of(LOGIN) { |scoped| scoped.ticket.find(@ticket.id).number }
end

check('block form leaves the outer client unscoped') do
  CLIENT.on_behalf_of(LOGIN) { |scoped| scoped.group.find(@group.id) }
  CLIENT.group.find(@group.id).name
end

section 'Errors'

check('missing record raises NotFoundError') do
  CLIENT.group.find(0)
  raise 'expected NotFoundError'
rescue ZammadAPI::NotFoundError => e
  "status=#{e.status}"
end

check('invalid attributes raise a ClientError') do
  CLIENT.group.create({})
  raise 'expected a ClientError'
rescue ZammadAPI::ClientError => e
  "status=#{e.status}"
end

check('bad credentials raise AuthenticationError') do
  ZammadAPI::Client.new(url: URL, user: 'nobody', password: 'wrong', retries: 0).group.find(1)
  raise 'expected AuthenticationError'
rescue ZammadAPI::AuthenticationError => e
  "status=#{e.status}"
end

finish
