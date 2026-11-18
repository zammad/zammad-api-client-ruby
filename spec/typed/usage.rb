# frozen_string_literal: true

# Never run. `rake steep` checks this file against the signatures the gem
# publishes, the way a typed project that uses the gem is checked, so that the
# types a caller gets are pinned by something other than the signatures saying
# so.
#
# A line that ends in `steep:ignore` is one that has to be a type error. Steep
# reports an ignore comment that silences nothing, so each of them fails the
# check on the day its line stops being an error. That is how "a record is
# typed" is asserted here: against an untyped record a misspelled reader is no
# error at all, and the comment beside it would be the redundant one.
module TypedUsage
  # A resource of the caller's own, reached through Client#resource.
  class Role < ZammadAPI::Resources::Base
    path 'api/v1/roles'
  end

  def self.title(client) = client.tickets.find(1).title

  def self.misspelled_reader(client)
    client.tickets.find(1).titel # steep:ignore NoMethod
  end

  def self.logins(client) = client.users.map(&:login)

  def self.block_parameter(client)
    client.users.each do |user|
      user.loginn.upcase # steep:ignore NoMethod
    end
  end

  def self.first_group(client) = client.groups.first

  def self.first_tickets(client) = client.tickets.first(5)

  def self.found(client) = client.organizations.find_by(name: 'Zammad')

  def self.newest_open(client)
    client.tickets.search('state.name:open').order(created_at: :desc).first&.number
  end

  def self.batches(client)
    sizes = [] #: Array[Integer]
    client.tickets.in_batches(of: 50) { |tickets| sizes << tickets.sum { it.article_count || 0 } }
    sizes
  end

  def self.customer_email(client) = client.tickets.find(1).related.customer&.email

  def self.article_bodies(client) = client.tickets.find(1).articles.map(&:body)

  def self.written(client)
    ticket = client.tickets.find(1)
    ticket.title = 'Printer on fire'
    ticket.title = 1 # steep:ignore ArgumentTypeMismatch
    ticket.number = '1' # steep:ignore NoMethod
    ticket.save
  end

  # An attribute an administrator added is read by name, or declared by the
  # project that knows about it - see usage.rbs.
  def self.custom_attribute(client)
    ticket = client.tickets.find(1)
    [ticket[:anything_at_all], ticket.escalation_reason]
  end

  def self.role_names(client)
    roles = client.resource(Role) #: ZammadAPI::ResourceProxy[Role]
    roles.map(&:name)
  end

  def self.unsaved(client) = client.ticket_states.new(name: 'waiting').name
end
