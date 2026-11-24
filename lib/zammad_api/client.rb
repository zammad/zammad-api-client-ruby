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
  #   client.tickets.find(1).title
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
      groups:            Resources::Group,
      organizations:     Resources::Organization,
      tickets:           Resources::Ticket,
      ticket_articles:   Resources::TicketArticle,
      ticket_priorities: Resources::TicketPriority,
      ticket_states:     Resources::TicketState,
      users:             Resources::User
    }.freeze

    # Methods Ruby calls implicitly for type coercion. They must keep raising
    # NoMethodError so that this object behaves normally in core operations.
    CONVERSION_METHODS = %i[to_ary to_a to_hash to_str to_io to_proc coerce].freeze

    # @return [Config] the validated configuration, with credentials redacted
    #   from its +inspect+ output
    attr_reader :config

    # @!method groups
    #   @return [ResourceProxy] proxy for {Resources::Group}
    # @!method organizations
    #   @return [ResourceProxy] proxy for {Resources::Organization}
    # @!method tickets
    #   @return [ResourceProxy] proxy for {Resources::Ticket}
    # @!method ticket_articles
    #   @return [ResourceProxy] proxy for {Resources::TicketArticle}
    # @!method ticket_priorities
    #   @return [ResourceProxy] proxy for {Resources::TicketPriority}
    # @!method ticket_states
    #   @return [ResourceProxy] proxy for {Resources::TicketState}
    # @!method users
    #   @return [ResourceProxy] proxy for {Resources::User}
    RESOURCES.each do |name, resource_class|
      define_method(name) { @resources.fetch(resource_class) }
    end

    # Environment variables {.from_env} reads, mapped to the options they set.
    ENV_OPTIONS = {
      'ZAMMAD_URL'          => :url,
      'ZAMMAD_TOKEN'        => :http_token,
      'ZAMMAD_HTTP_TOKEN'   => :http_token,
      'ZAMMAD_OAUTH2_TOKEN' => :oauth2_token,
      'ZAMMAD_USER'         => :user,
      'ZAMMAD_PASSWORD'     => :password
    }.freeze

    # Builds a client from the environment.
    #
    # Reads {ENV_OPTIONS}; a variable that is empty or blank counts as unset,
    # and +ZAMMAD_HTTP_TOKEN+ wins over +ZAMMAD_TOKEN+. Anything passed in wins
    # over the environment, and credentials passed in replace the ones the
    # environment holds.
    #
    # @example
    #   ZAMMAD_URL=https://zammad.example.com/ ZAMMAD_TOKEN=secret ruby report.rb
    #
    #   client = ZammadAPI::Client.from_env
    #   client = ZammadAPI::Client.from_env(timeout: 300) # for one bulk job
    #
    # @param overrides [Hash] any option accepted by {Config}
    # @return [Client]
    # @raise [ConfigurationError] when neither the environment nor +overrides+
    #   supply a URL and credentials
    def self.from_env(**overrides)
      from_environment = ENV_OPTIONS.filter_map do |name, option|
        value = ENV.fetch(name, nil)
        [option, value] if !value.to_s.strip.empty?
      end
      options = Config.merge_options(from_environment.to_h, overrides)

      raise ConfigurationError, "missing url: set ZAMMAD_URL or pass url: to #{name}.from_env" if options[:url].to_s.empty?

      new(**options)
    end

    # Builds a client from a {Config} that is already validated and a
    # transport that is already built, for {Test}.
    #
    # @api private
    # @param config [Config]
    # @param transport [Transport] anything with a {Transport} interface
    # @return [Client]
    def self.build(config, transport)
      allocate.send(:setup, config, transport)
    end

    # @param options [Hash] see {Config} for every supported option
    # @option options [String] :url base URL of the Zammad instance
    # @option options [String] :http_token access token
    # @option options [String] :oauth2_token OAuth2 token
    # @option options [String] :user login for basic authentication
    # @option options [String] :password password for basic authentication
    # @raise [ConfigurationError] when the options are incomplete or invalid,
    #   or name more than one way to authenticate
    def initialize(**options)
      config = Config.new(**options)
      setup(config, Transport.new(config))
    end

    # The proxy for a resource, by name or by class. A class is the way to
    # the parts of the API this gem does not model.
    #
    # @example A resource this gem does not model
    #   class Role < ZammadAPI::Resources::Base
    #     path 'api/v1/roles'
    #   end
    #
    #   client.resource(Role).each { |role| puts role.name }
    #
    # @param name [Symbol, String, Class] a key of {RESOURCES}, or a subclass
    #   of {Resources::Base}
    # @return [ResourceProxy]
    # @raise [UnknownResourceError] when no resource has that name
    # @raise [ArgumentError] for a class that is not a resource
    # @raise [Error] for a resource class that declares no path
    def resource(name)
      return proxy_for(name) if name.is_a?(Class)

      resource_class = RESOURCES.fetch(name.to_sym) { raise UnknownResourceError, unknown_resource_message(name) }

      @resources.fetch(resource_class)
    end

    # @return [Array<Symbol>] every resource name this client supports
    def resource_names = RESOURCES.keys

    # The user these requests authenticate as, or the one {#on_behalf_of}
    # scoped them to.
    #
    # @example Checking which account a token belongs to
    #   client.me.email # => "agent@example.com"
    #
    # @return [Resources::User]
    # @raise [AuthenticationError] when the credentials are not valid
    def me
      operation = 'find current user'
      response  = @transport.get(
        "#{Resources::User.resource_path}/me",
        operation:      operation,
        resource_class: Resources::User,
        query:          { expand: true }
      )
      Resources::User.from_response(@transport, response.decoded(:object, operation: operation, resource_class: Resources::User))
    end

    # The version of the Zammad instance, not of this gem — that is
    # {ZammadAPI::VERSION}. Zammad serves it to administrators only.
    #
    # @example
    #   client.version # => "6.4.0"
    #
    # @return [String, nil] nil when the instance reported no version
    # @raise [AuthorizationError] when the account is not an administrator
    def version
      response = @transport.get('api/v1/version', operation: 'get the Zammad version')
      response.decoded(:object, operation: 'get the Zammad version')[:version]&.to_s
    end

    # @!group Raw requests

    # Performs a +GET+ against any endpoint of the Zammad API, with the
    # client's authentication, retries, JSON decoding and error classes.
    #
    # @example An endpoint this gem does not model
    #   client.get('api/v1/roles').body
    #   # => [{id: 1, name: "Admin", ...}, ...]
    #
    # @example An endpoint that needs a header of its own
    #   client.get('api/v1/tickets/1', headers: {'Accept-Language' => 'de-de'})
    #
    # @param path [String] path relative to {Config#url}; a leading slash is
    #   ignored, and an absolute URL is refused, so the client's credentials
    #   only ever go to the instance it was configured for
    # @param query [Hash, nil] query string parameters
    # @param headers [Hash, nil] request headers
    # @return [Response]
    # @raise [ResponseError] for any non-2xx response
    # @raise [TransportError] when the request could not be completed
    # @raise [ArgumentError] for a path that is an absolute URL
    def get(path, query: nil, headers: nil) = raw(:get, path, query: query, headers: headers)

    # Performs a +POST+ against any endpoint of the Zammad API.
    #
    # @example
    #   client.post('api/v1/tags/add', query: {object: 'Ticket', o_id: 1, item: 'urgent'})
    #
    # @param path [String] path relative to {Config#url}
    # @param query [Hash, nil] query string parameters
    # @param body [Hash, Array, nil] request payload, encoded as JSON
    # @param headers [Hash, nil] request headers
    # @return [Response]
    # @raise [ResponseError] for any non-2xx response
    # @see #get
    def post(path, query: nil, body: nil, headers: nil) = raw(:post, path, query: query, body: body, headers: headers)

    # Performs a +PUT+ against any endpoint of the Zammad API.
    #
    # @param path [String] path relative to {Config#url}
    # @param query [Hash, nil] query string parameters
    # @param body [Hash, Array, nil] request payload, encoded as JSON
    # @param headers [Hash, nil] request headers
    # @return [Response]
    # @raise [ResponseError] for any non-2xx response
    # @see #get
    def put(path, query: nil, body: nil, headers: nil) = raw(:put, path, query: query, body: body, headers: headers)

    # Performs a +DELETE+ against any endpoint of the Zammad API.
    #
    # @param path [String] path relative to {Config#url}
    # @param query [Hash, nil] query string parameters
    # @param headers [Hash, nil] request headers
    # @return [Response]
    # @raise [ResponseError] for any non-2xx response
    # @see #get
    def delete(path, query: nil, headers: nil) = raw(:delete, path, query: query, headers: headers)

    # @!endgroup

    # Returns a new client with some configuration options changed.
    #
    # The options are re-validated, and any {#on_behalf_of} scope is carried
    # over. Naming credentials replaces the ones this client has.
    #
    # @example A longer timeout for one bulk job
    #   bulk = client.with(timeout: 300, retries: 5)
    #
    # @param options [Hash] any option accepted by {Config}
    # @return [Client]
    # @raise [ConfigurationError] when the resulting options are invalid
    def with(**options)
      derived_config = config.with(**options)
      dup.send(:setup, derived_config, @transport.with_config(derived_config))
    end

    # Performs requests on behalf of another user, through a new client.
    #
    # @example Scoped client
    #   support = client.on_behalf_of('agent@example.com')
    #   support.tickets.create(title: 'Help', group: 'Users', customer_id: 1)
    #
    # @example Block form
    #   client.on_behalf_of('agent@example.com') do |scoped|
    #     scoped.tickets.find(1)
    #   end
    #
    # @param identifier [String, Integer] login, email address or user id
    # @yieldparam scoped [Client]
    # @return [Client] when no block is given, otherwise the block's value
    # @raise [ArgumentError] for an identifier that is nil or blank, which
    #   would quietly leave the requests unscoped
    def on_behalf_of(identifier)
      scoped = dup.send(:setup, config, @transport.with_on_behalf_of(Transport.on_behalf_of_header(identifier)))
      return scoped if !block_given?

      yield scoped
    end

    def inspect
      scope = @transport.on_behalf_of

      "#<#{self.class.name} url=#{config.url.inspect} auth=#{config.authentication_scheme}#{" on_behalf_of=#{scope.inspect}" if scope}>"
    end

    def method_missing(name, *args)
      return super if CONVERSION_METHODS.include?(name) || name.to_s.end_with?('=', '!', '?')

      raise UnknownResourceError, unknown_resource_message(name)
    end

    def respond_to_missing?(_name, _include_private = false) = false

    private

    def raw(method, path, query: nil, body: nil, headers: nil)
      relative = Transport.relative_path(path)

      @transport.request(
        method,
        relative,
        operation: "#{method.to_s.upcase} #{Transport.redact_path(relative)}",
        query:     query,
        body:      body,
        headers:   headers
      )
    end

    def unknown_resource_message(name) = "Unknown resource #{name}, available resources are: #{RESOURCES.keys.join(', ')}"

    def proxy_for(resource_class)
      raise ArgumentError, "resource takes the name of a resource or a subclass of #{Resources::Base.name}, and #{resource_class.inspect} is neither" if !(resource_class <= Resources::Base)

      @resources.fetch(resource_class) do
        resource_class.resource_path
        ResourceProxy.new(@transport, resource_class)
      end
    end

    # Everything a client is, in the one place {.new}, {.build}, {#with} and
    # {#on_behalf_of} go through. The proxies are built up front so that a
    # client is immutable, and safe to share between threads, once built.
    #
    # @return [self]
    def setup(config, transport)
      @config    = config
      @transport = transport
      @resources = RESOURCES.values.to_h { [it, ResourceProxy.new(transport, it)] }.freeze

      self
    end
  end
end
