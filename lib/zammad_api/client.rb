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
    #
    # Plural, because what a reader hands back stands for every record of
    # its kind: a {ResourceProxy} is +Enumerable+ over all of them, so
    # +client.tickets.each+ and +client.tickets.first(5)+ say what they do,
    # where the singular the readers had in 1.x read as if it acted on one
    # ticket. That name dates from when a proxy was only a dispatcher for
    # +find+ and +create+.
    RESOURCES = {
      groups:            Resources::Group,
      organizations:     Resources::Organization,
      tickets:           Resources::Ticket,
      ticket_articles:   Resources::TicketArticle,
      ticket_priorities: Resources::TicketPriority,
      ticket_states:     Resources::TicketState,
      users:             Resources::User
    }.freeze

    # The names the readers had in 1.x, mapped to the ones they have now.
    # Each still works, as a deprecated alias - see {#resource}.
    DEPRECATED_RESOURCES = {
      group:           :groups,
      organization:    :organizations,
      ticket:          :tickets,
      ticket_article:  :ticket_articles,
      ticket_priority: :ticket_priorities,
      ticket_state:    :ticket_states,
      user:            :users
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

    # @!method group
    #   @deprecated Use {#groups}.
    #   @return [ResourceProxy]
    # @!method organization
    #   @deprecated Use {#organizations}.
    #   @return [ResourceProxy]
    # @!method ticket
    #   @deprecated Use {#tickets}.
    #   @return [ResourceProxy]
    # @!method ticket_article
    #   @deprecated Use {#ticket_articles}.
    #   @return [ResourceProxy]
    # @!method ticket_priority
    #   @deprecated Use {#ticket_priorities}.
    #   @return [ResourceProxy]
    # @!method ticket_state
    #   @deprecated Use {#ticket_states}.
    #   @return [ResourceProxy]
    # @!method user
    #   @deprecated Use {#users}.
    #   @return [ResourceProxy]
    DEPRECATED_RESOURCES.each do |old_name, name|
      define_method(old_name) do
        Client.warn_deprecated_resource(old_name, name)
        @resources.fetch(RESOURCES.fetch(name))
      end
    end

    # Says that a reader was called by the name it had in 1.x.
    #
    # In Ruby's own +deprecated+ category, so it is silent unless the
    # application asks for deprecation warnings - +ruby -W:deprecated+, or
    # +Warning[:deprecated] = true+, which is what a test suite turns on -
    # and a script that has not been migrated yet does not print a line per
    # request in production. +uplevel+ names the line that made the call,
    # past the two frames of this class in between.
    #
    # @api private
    # @param old_name [Symbol]
    # @param name [Symbol]
    # @return [void]
    def self.warn_deprecated_resource(old_name, name)
      warn("ZammadAPI::Client##{old_name} is deprecated and will be removed in 3.0: use ##{name} instead", uplevel: 2, category: :deprecated)
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
    # Reads {ENV_OPTIONS}, so a script needs no configuration of its own.
    # Anything passed in wins over the environment, and every other option
    # keeps its default. That includes the way to authenticate: passing
    # +user:+ and +password:+, or a token, replaces whichever credentials the
    # environment holds rather than sitting beside them. An empty variable
    # counts as unset, and +ZAMMAD_HTTP_TOKEN+ wins over +ZAMMAD_TOKEN+ if
    # both are set. An environment that sets more than one way to
    # authenticate - a token and a user with a password - is refused like
    # any other configuration that does, unless an argument names the one to
    # use.
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
        [option, value] if !value.to_s.empty?
      end
      options = Config.merge_options(from_environment.to_h, overrides)

      raise ConfigurationError, "missing url: set ZAMMAD_URL or pass url: to #{name}.from_env" if options[:url].to_s.empty?

      new(**options)
    end

    # Builds a client from a {Config} that is already validated and a
    # transport that is already built.
    #
    # The public constructor turns options into a Config and a Config into a
    # Transport, and building a Transport means building a Faraday stack:
    # authentication, JSON, the retry middleware, adapter resolution. Anything
    # holding a transport of its own - {Test} - threw all of that away one
    # line later, and paid for it again for every stand-in a suite builds.
    # This is the way in for those, and the reason there is no public
    # `with_transport` to swap one in after the fact.
    #
    # @api private
    # @param config [Config] an already validated configuration
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

    # The proxy for a resource, by name or by class.
    #
    # A name from 1.x - +:ticket+ for +:tickets+ - is still answered, with
    # a deprecation warning.
    #
    # A class is the way to the parts of the API this gem does not model.
    # {Resources::Base} is built to be subclassed - a path, and whatever the
    # endpoint needs said about it - and a proxy for such a class gives its
    # records everything the modelled ones have: pagination, +find_by+,
    # change tracking, +save+. 1.x reached any subclass through +const_get+
    # on a name a caller supplied, and 2.0 closed that, which left raw
    # requests as the only way to the rest of the API; this is the same
    # reach, with the class handed over rather than looked up.
    #
    # @example A resource this gem does not model
    #   class Role < ZammadAPI::Resources::Base
    #     path 'api/v1/roles'
    #   end
    #
    #   client.resource(Role).each { |role| puts role.name }
    #   client.resource(Role).find(2).update(note: 'Reviewed')
    #
    # @param name [Symbol, String, Class] a key of {RESOURCES}, or a subclass
    #   of {Resources::Base}
    # @return [ResourceProxy]
    # @raise [UnknownResourceError] when no resource has that name
    # @raise [ArgumentError] for a class that is not a resource
    # @raise [Error] for a resource class that declares no path
    def resource(name)
      return proxy_for(name) if name.is_a?(Class)

      key = name.to_sym

      if !RESOURCES.key?(key)
        current = DEPRECATED_RESOURCES.fetch(key) { raise UnknownResourceError, unknown_resource_message(name) }
        Client.warn_deprecated_resource(key, current)
        key = current
      end

      @resources.fetch(RESOURCES.fetch(key))
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
      response = @transport.get(
        # Derived from the resource that declares the endpoint, not spelled
        # out again: `member_path` exists for the same reason, and a path kept
        # in two places is one that moves in one of them. Spelled out here,
        # `client.users` would follow the users endpoint wherever it went and
        # `client.me` would keep requesting the old one.
        "#{Resources::User.resource_path}/me",
        operation:      'find current user',
        resource_class: Resources::User,
        query:          { expand: true }
      )
      Resources::User.from_response(
        @transport,
        response.decoded(:object, operation: 'find current user', resource_class: Resources::User)
      )
    end

    # The version of the Zammad instance, not of this gem — that is
    # {ZammadAPI::VERSION}.
    #
    # @example
    #   client.version # => "6.4.0"
    #
    # @return [String, nil] nil when the instance reported no version
    def version
      response = @transport.get('api/v1/version', operation: 'get the Zammad version')
      version  = response.decoded(:object, operation: 'get the Zammad version')[:version]
      version&.to_s
    end

    # @!group Raw requests

    # Performs a +GET+ against any endpoint of the Zammad API.
    #
    # The resource classes cover a part of the API; these four methods reach
    # the rest of it without giving up authentication, retries, credential
    # redaction, JSON decoding or the error classes.
    #
    # +headers:+ is here because an escape hatch that cannot set one does not
    # reach an endpoint that needs one. What it will not set is the two
    # headers this client owns - see the +headers+ parameter below.
    #
    # @example An endpoint this gem does not model
    #   client.get('api/v1/roles').body
    #   # => [{id: 1, name: "Admin", ...}, ...]
    #
    # @example Reading a response header
    #   client.get('api/v1/tickets').headers['content-type']
    #
    # @example An endpoint that needs a header of its own
    #   client.get('api/v1/tickets/1', headers: {'Accept-Language' => 'de-de'})
    #
    # @param path [String] path relative to {Config#url}; a leading slash is
    #   ignored, so paths can be pasted from the Zammad documentation. An
    #   absolute URL is refused, so the client's credentials only ever go to
    #   the instance it was configured for.
    # @param query [Hash, nil] query string parameters
    # @param headers [Hash, nil] request headers. Names are case-insensitive,
    #   and +Authorization+ and +From+ are refused: the first is what the
    #   client's credentials are for, the second is what {#on_behalf_of} sets.
    # @return [Response]
    # @raise [ResponseError] for any non-2xx response
    # @raise [TransportError] when the request could not be completed
    # @raise [ArgumentError] for a header this client sets itself, a value
    #   that is not text, or a path that is an absolute URL
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
    # over. The original client keeps its own connection and settings.
    #
    # Naming credentials replaces the ones this client has, whichever kind
    # they were: +with(oauth2_token: 'x')+ on a client built with an access
    # token authenticates with the OAuth2 token alone.
    #
    # The transport derives from the current one rather than being built from
    # scratch, so a client wired to a stand-in stays wired to it.
    #
    # @example A longer timeout for one bulk job
    #   bulk = client.with(timeout: 300, retries: 5)
    #   bulk.tickets.all.each { |ticket| archive(ticket) }
    #
    # @param options [Hash] any option accepted by {Config}
    # @return [Client]
    # @raise [ConfigurationError] when the resulting options are invalid
    def with(**options)
      derived_config = config.with(**options)
      dup.send(:setup, derived_config, @transport.with_config(derived_config))
    end

    # Performs requests on behalf of another user.
    #
    # Returns a new client rather than mutating this one, so the original
    # client is unaffected and both can be used concurrently.
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
    # An identifier that names nobody is refused. Zammad skips a +From+
    # header with nothing in it, and a nil sent none at all, so
    # +client.on_behalf_of(current_user&.login)+ with nobody signed in
    # handed back a client that looked scoped and was not: every request
    # ran with the rights of the account the client authenticates as, and
    # a list read through it held everything that account can see. No
    # request failed, so nothing said the scope was missing.
    #
    # @param identifier [String, Integer] login, email address or user id
    # @yieldparam scoped [Client]
    # @return [Client] when no block is given, otherwise the block's value
    # @raise [ArgumentError] for an identifier that is nil, empty or blank
    def on_behalf_of(identifier)
      raise ArgumentError, blank_on_behalf_of_message(identifier) if identifier.nil? || identifier.to_s.strip.empty?

      scoped = dup.send(:setup, config, @transport.with_on_behalf_of(identifier))
      return scoped if !block_given?

      yield scoped
    end

    # The scope is shown where there is one, so that a client acting for
    # another user does not print as the one it was derived from.
    def inspect
      scope = @transport.on_behalf_of

      "#<#{self.class.name} url=#{config.redacted_url.inspect} auth=#{config.authentication_scheme}#{" on_behalf_of=#{scope.inspect}" if scope}>"
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
        operation: "#{method.to_s.upcase} #{relative}",
        query:     query,
        body:      body,
        headers:   headers
      )
    end

    def unknown_resource_message(name) = "Unknown resource #{name}, available resources are: #{RESOURCES.keys.join(', ')}"

    def blank_on_behalf_of_message(identifier)
      "on_behalf_of needs the login, email address or id of a user, and was given #{identifier.inspect}. " \
        'Zammad reads a From header with nothing in it as no header at all, so every request would be performed ' \
        'as the account this client authenticates as, with nothing to say the scope was missing.'
    end

    # One of the proxies built with this client for a class it models, and a
    # new one for any other resource class. A new one each time, rather than
    # a memo: the client is frozen in everything but name once it is built -
    # see {#setup} - and a proxy holds nothing but the transport and the
    # class.
    def proxy_for(resource_class)
      raise ArgumentError, "resource takes the name of a resource or a subclass of #{Resources::Base.name}, and #{resource_class.inspect} is neither" if !(resource_class <= Resources::Base)

      @resources.fetch(resource_class) do
        # Asked for now, so that a class without a path is reported by the
        # call that named it rather than by its first request.
        resource_class.resource_path
        ResourceProxy.new(@transport, resource_class)
      end
    end

    # Everything a client is, in the one place all four ways of making one go
    # through: {.new}, {.build}, {#with} and {#on_behalf_of}. Held apart,
    # `build` restated `initialize`'s list of instance variables by hand, and
    # the fourth one added to `initialize` would have left every client built
    # for a test unset where it mattered.
    #
    # The proxies are built here rather than memoized on first use, because a
    # client is documented - and used, in examples/concurrent_sync.rb - as
    # immutable once built and safe to share between threads without locking.
    # A memo populated by the first `client.tickets` in each worker is a write
    # to shared state, and while CRuby's GVL makes it harmless, a contract
    # that only holds on one implementation is not the contract that was
    # written down. Building all seven up front costs an allocation each and
    # keeps the object finished the moment it is handed back.
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
