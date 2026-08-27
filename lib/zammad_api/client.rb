# frozen_string_literal: true

require_relative 'config'
require_relative 'errors'
require_relative 'resource_proxy'
require_relative 'resources'
require_relative 'transport'

module ZammadAPI
  # The entry point of this gem.
  #
  # @example Token authentication
  #   client = ZammadAPI::Client.new(
  #     url:        'https://zammad.example.com/',
  #     http_token: 'your-access-token'
  #   )
  #   client.ticket.find(1).title
  #
  # @example Basic authentication with a custom timeout and logger
  #   client = ZammadAPI::Client.new(
  #     url:      'https://zammad.example.com/',
  #     user:     'user@example.com',
  #     password: 'secret',
  #     timeout:  10,
  #     logger:   Logger.new($stdout)
  #   )
  class Client
    # Maps the reader methods of this client to their resource classes.
    RESOURCES = {
      group:           Resources::Group,
      organization:    Resources::Organization,
      ticket:          Resources::Ticket,
      ticket_article:  Resources::TicketArticle,
      ticket_priority: Resources::TicketPriority,
      ticket_state:    Resources::TicketState,
      user:            Resources::User
    }.freeze

    # Methods Ruby calls implicitly for type coercion. They must keep raising
    # NoMethodError so that this object behaves normally in core operations.
    CONVERSION_METHODS = %i[to_ary to_a to_hash to_str to_io to_proc coerce].freeze

    # @return [Config] the validated configuration, with credentials redacted
    #   from its +inspect+ output
    attr_reader :config

    # @!method group
    #   @return [ResourceProxy] proxy for {Resources::Group}
    # @!method organization
    #   @return [ResourceProxy] proxy for {Resources::Organization}
    # @!method ticket
    #   @return [ResourceProxy] proxy for {Resources::Ticket}
    # @!method ticket_article
    #   @return [ResourceProxy] proxy for {Resources::TicketArticle}
    # @!method ticket_priority
    #   @return [ResourceProxy] proxy for {Resources::TicketPriority}
    # @!method ticket_state
    #   @return [ResourceProxy] proxy for {Resources::TicketState}
    # @!method user
    #   @return [ResourceProxy] proxy for {Resources::User}
    RESOURCES.each_key do |name|
      define_method(name) { resource(name) } # steep:ignore NoMethod
    end

    # @param options [Hash] see {Config} for every supported option
    # @option options [String] :url base URL of the Zammad instance
    # @option options [String] :http_token access token
    # @option options [String] :oauth2_token OAuth2 token
    # @option options [String] :user login for basic authentication
    # @option options [String] :password password for basic authentication
    # @raise [ConfigurationError] when the options are incomplete or invalid
    def initialize(**options)
      @config    = Config.new(**options)
      @transport = Transport.new(@config)
    end

    # @param name [Symbol, String] a key of {RESOURCES}
    # @return [ResourceProxy]
    # @raise [UnknownResourceError] when the resource is not known
    def resource(name)
      resource_class = RESOURCES.fetch(name.to_sym) { raise UnknownResourceError, unknown_resource_message(name) }
      ResourceProxy.new(@transport, resource_class)
    end

    # @return [Array<Symbol>] every resource name this client supports
    def resource_names = RESOURCES.keys

    # Returns a new client with some configuration options changed.
    #
    # The options are re-validated, and any {#on_behalf_of} scope is carried
    # over. The original client keeps its own connection and settings.
    #
    # @example A longer timeout for one bulk job
    #   bulk = client.with(timeout: 300, retries: 5)
    #   bulk.ticket.all.each { |ticket| archive(ticket) }
    #
    # @param options [Hash] any option accepted by {Config}
    # @return [Client]
    # @raise [ConfigurationError] when the resulting options are invalid
    def with(**options)
      derived_config = config.with(**options)
      derived        = dup
      derived.instance_variable_set(:@config, derived_config)
      derived.instance_variable_set(
        :@transport,
        Transport.new(derived_config).with_on_behalf_of(@transport.on_behalf_of)
      )
      derived
    end

    # Performs requests on behalf of another user.
    #
    # Returns a new client rather than mutating this one, so the original
    # client is unaffected and both can be used concurrently.
    #
    # @example Scoped client
    #   support = client.on_behalf_of('agent@example.com')
    #   support.ticket.create(title: 'Help', group: 'Users', customer_id: 1)
    #
    # @example Block form
    #   client.on_behalf_of('agent@example.com') do |scoped|
    #     scoped.ticket.find(1)
    #   end
    #
    # @param identifier [String, Integer] login, email address or user id
    # @yieldparam scoped [Client]
    # @return [Client] when no block is given, otherwise the block's value
    def on_behalf_of(identifier)
      scoped = dup
      scoped.instance_variable_set(:@transport, @transport.with_on_behalf_of(identifier))
      return scoped if !block_given?

      yield scoped
    end

    def inspect = "#<#{self.class.name} url=#{config.url.inspect} auth=#{config.authentication_scheme}>"

    def method_missing(name, *args)
      return super if CONVERSION_METHODS.include?(name) || name.to_s.end_with?('=', '!', '?')

      raise UnknownResourceError, unknown_resource_message(name)
    end

    def respond_to_missing?(_name, _include_private = false) = false

    private

    def unknown_resource_message(name) = "Unknown resource #{name}, available resources are: #{RESOURCES.keys.join(', ')}"
  end
end
