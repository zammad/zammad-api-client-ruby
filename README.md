# Zammad API Client (Ruby)

[![Gem Version](https://badge.fury.io/rb/zammad_api.svg)](https://badge.fury.io/rb/zammad_api)
[![CI](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml)

> [!IMPORTANT]
> `2.0.0.alpha1` is the first prerelease of a breaking 2.0. Names and defaults can still
> change: [open an issue](https://github.com/zammad/zammad-api-client-ruby/issues/new) with
> anything that reads wrong, is missing, or makes upgrading hard. Rough notes are welcome.
> On 1.x? See [UPGRADING.md](UPGRADING.md), which also says how to stay on 1.x.

Ruby client for the Zammad API v1.0.

- Tickets, articles, attachments, users, organizations, groups, ticket states and
  priorities as records you `find`, `create`, `update` and `destroy`.
- Collections that paginate themselves: `each`, `first`, `search`, `find_each`.
- Timeouts, and retries for `GET`, on by default, and one error class per kind of failure.
- Any other endpoint through a resource you declare or a raw request.

## Installation

Requires Ruby 3.4 or later. 2.0 is a prerelease, and a prerelease has to be asked for:

```ruby
gem 'zammad_api', '~> 2.0.0.alpha'
```

Or:

```sh
gem install zammad_api --pre
```

## Quick start

```ruby
require 'zammad_api'

client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'your-access-token'
)

client.tickets.first(5).each { |ticket| puts ticket.title }

ticket = client.tickets.create(
  title:    'Cannot log in',
  group:    'Users',
  customer: 'nicole.braun@zammad.org',
  article:  {subject: 'Cannot log in', body: 'My password stopped working.', type: 'note'}
)

ticket.add_article(body: 'Reset link sent.', type: 'note')
ticket.update(state: 'closed')

client.tickets.search('state.name:open').each { |open_ticket| puts open_ticket.number }

begin
  client.tickets.find(123_456)
rescue ZammadAPI::NotFoundError => e
  warn e.server_message
end
```

The sections below cover [creating a client](#creating-a-client),
[records](#working-with-records), [collections](#collections) and
[error handling](#error-handling). Runnable scripts live in [`examples/`](examples/README.md).

## Creating a client

### Authentication

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'your-access-token'
)
```

Or pass `oauth2_token:`, or `user:` and `password:`. Pass one kind of credentials: more
than one raises `ZammadAPI::ConfigurationError`.

### From the environment

`from_env` reads `ZAMMAD_URL` and one of `ZAMMAD_TOKEN`, `ZAMMAD_OAUTH2_TOKEN`, or
`ZAMMAD_USER` with `ZAMMAD_PASSWORD`. Options passed to it override the environment:

```ruby
client = ZammadAPI::Client.from_env
client = ZammadAPI::Client.from_env(timeout: 300)
```

### Options

| Option           | Default            | Description                                                        |
| ---------------- | ------------------ | ------------------------------------------------------------------ |
| `url`            | *required*         | Base URL. A sub-path such as `https://example.com/zammad/` works; credentials in it are refused. |
| `http_token`     | `nil`              | Zammad access token.                                               |
| `oauth2_token`   | `nil`              | OAuth2 bearer token.                                               |
| `user`           | `nil`              | Login for basic authentication.                                    |
| `password`       | `nil`              | Password for basic authentication.                                 |
| `timeout`        | `60`               | Seconds to wait for a response.                                    |
| `open_timeout`   | `10`               | Seconds to wait for the connection.                                |
| `retries`        | `2`                | Retry attempts for a `GET` that failed transiently. `0` disables retrying. |
| `retry_interval` | `0.5`              | Seconds before the first retry; doubles on each attempt.           |
| `ssl_verify`     | `true`             | Set to `false` only against a server with a self-signed certificate. |
| `proxy`          | `nil`              | Proxy URL.                                                         |
| `user_agent`     | `zammad_api-ruby/<version>` | Value of the `User-Agent` header.                         |
| `logger`         | discards output    | Any `Logger`; see [Logging](#logging).                             |
| `adapter`        | Faraday's default  | Name of a Faraday adapter; see [Adapter and middleware](#adapter-and-middleware). |
| `middleware`     | `nil`              | Callable that is handed the Faraday connection while it is built.  |

Credentials are never logged, and `client.config` redacts them when printed.

### Changing options

A client is immutable. `with` returns a new one with some options changed, carrying over
any `on_behalf_of` scope:

```ruby
bulk = client.with(timeout: 300, retries: 5)
bulk.tickets.each { |ticket| archive(ticket) }
```

Naming credentials replaces the ones the client has, whichever kind they were. Because
clients are immutable, one client and anything derived from it can be shared between
threads.

### Checking the connection

```ruby
client.me.email # => "agent@example.com", the account the credentials belong to
client.version  # => "6.4.0", the Zammad instance's version, for an administrator
```

`client.me` works for any account, so use it to check that the client can reach Zammad and
authenticate. Zammad serves `client.version` to administrators only: with an agent's or a
customer's credentials it raises `ZammadAPI::AuthorizationError`. `ZammadAPI::VERSION` is
the version of this gem.

## Resources

`groups`, `organizations`, `tickets`, `ticket_articles`, `ticket_priorities`,
`ticket_states`, `users`

`client.resource_names` returns the current list. Anything else is reachable by declaring
a resource or with raw requests; see
[Endpoints this gem does not model](#endpoints-this-gem-does-not-model).

## Working with records

### Create

```ruby
user = client.users.new(firstname: 'Nicole', lastname: 'Braun', email: 'nicole.braun@zammad.org')
user.save

user.id    # => 42
user.email # => "nicole.braun@zammad.org"
```

Or in one call:

```ruby
user = client.users.create(firstname: 'Nicole', lastname: 'Braun', email: 'nicole.braun@zammad.org')
```

Attributes are a Hash, or anything that converts to one with `to_hash`. In a Rails
controller that is the permitted parameters:

```ruby
client.users.create(params.require(:user).permit(:login, :email, :password))
```

### Fetch

```ruby
user = client.users.find(42)                       # raises NotFoundError if there is none

client.users.find_by(email: 'someone@example.com') # => the record, or nil
client.users.find_by!(email: 'nobody@example.com') # raises NotFoundError
client.users.exists?(42)                           # => true
```

`find_by` returns the first record carrying all of the given values, or `nil`. It searches
where the resource has a search endpoint and one of the values is a String; otherwise it
reads the index page by page, which can take many requests on a large instance. What a
search matches is up to Zammad's search index, so where a miss must be certain, read the
index yourself: `client.tickets.detect { it[:state] == 'open' }`.

### Reading attributes

```ruby
user.email         # => "nicole.braun@zammad.org"
user[:email]       # the same, and nil when the attribute is absent
user.fetch(:email) # raises KeyError when the attribute is absent
user.key?(:email)  # => true
user.to_h          # every attribute, as a Hash you may modify
```

A reader for an attribute the record does not carry raises `NoMethodError`, so a typo does
not read as `nil`. Use `record[:name]` or `fetch(:name, nil)` where an attribute may be
absent: custom attributes, or records the authenticated user may only partly see.

`attributes` and `changes` are frozen. Assign through a writer (`user.email = '...'`) to
stage a change.

### Update

```ruby
user = client.users.find(42)
user.firstname = 'Nicola'

user.changed? # => true
user.changes  # => {firstname: ["Nicole", "Nicola"]}

user.save     # sends only the changed attributes
```

`save` with no changes sends no request and returns `true`. Assigning the value an
attribute already has is not a change.

Or in one call:

```ruby
user.update(firstname: 'Nicola', note: 'Renamed')  # assigns, then saves
user.assign_attributes(firstname: 'Nicola')        # assigns without saving
```

### Saving and validation failures

`save` returns whether the record was stored, and leaves a rejection in `error`:

```ruby
group = client.groups.new(name: '')

if group.save
  puts group.id
else
  warn group.error.server_message # => "Name is required"
end
```

Only a validation failure (HTTP 422) is reported this way. Every other failure raises.

`save!` and `update!` raise on every failure, including validation:

```ruby
group.save!               # raises ZammadAPI::ValidationError
group.update!(name: '')   # the same, in one call
```

`create` raises on a validation failure, like `save!`. Use `new` and `save` to branch
instead.

### Reload and destroy

```ruby
user.reload  # re-reads from Zammad, discarding unsaved changes
user.destroy # => true

user.destroyed?  # => true
user.persisted?  # => false

client.users.destroy(42) # delete by id, without fetching first
```

### Associations

Zammad expands an association into a name beside the id, so those reads cost nothing:

```ruby
ticket = client.tickets.find(1)

ticket.customer    # => "customer@example.com"
ticket.state       # => "open"
ticket.group       # => "Users"
ticket.customer_id # => 7
```

The whole record behind one of those is a `find` by its id, which costs a request:

```ruby
client.users.find(ticket.customer_id).firstname # => "Nicole"
```

A foreign key that may be empty, such as a user's `organization_id`, is `nil` then, and
`find` needs an id:

```ruby
user.organization_id && client.organizations.find(user.organization_id)
```

### Articles and attachments

```ruby
ticket.articles                                             # => [TicketArticle, ...]
ticket.add_article(body: 'Reset link sent.', type: 'note')  # => the created TicketArticle

ticket.articles.each do |article|
  article.attachments.each do |attachment|
    File.binwrite(File.basename(attachment.filename), attachment.download)
  end
end
```

`articles` is one request, and is fetched on each call. `download` returns the file
contents as a binary String.

### Comparing and serializing

Two records of the same kind with the same id are equal, so `uniq`, `Set` and `include?`
work as expected:

```ruby
client.tickets.find(1) == client.tickets.find(1)  # => true
```

`to_json` renders the attributes, and `as_json` returns them as a Hash:

```ruby
client.groups.find(1).to_json # => "{\"id\":1,\"name\":\"Support\"}"
```

### Pattern matching

Records implement `deconstruct_keys`, so they work with `case/in`:

```ruby
case client.tickets.find(1)
in {state: 'closed'}
  nil
in {state: String => state, priority: '3 high'}
  escalate(state)
in {group: 'Support'}
  notify_support
end
```

## Collections

`all`, `search` and `order` return a `ZammadAPI::Collection`. It is `Enumerable`, makes no
request until you iterate, and fetches pages as needed.

### Iterating

```ruby
client.tickets.each { |ticket| puts ticket.title }

# One request, for five records.
client.tickets.first(5)

# Lazy chains stop fetching once they have enough.
client.tickets.lazy.select { |ticket| ticket.state == 'open' }.first(10)

# One array of records per request, e.g. for a bulk import.
client.tickets.in_batches(of: 50) { |tickets| import(tickets) }

# Record by record, 50 per request.
client.tickets.find_each(batch_size: 50) { |ticket| archive(ticket) }

# Attribute values instead of records.
client.users.pluck(:email)        # => ["a@example.com", ...]
client.tickets.pluck(:id, :title) # => [[1, "Help"], ...]
```

`client.tickets` and `client.tickets.all` are the same collection. Nothing is cached, so
iterating again fetches again.

`client.tickets.find(1)` looks up by id. To find with a block, use `detect`.

### Searching

```ruby
client.tickets.search('state.name:open').each { |ticket| puts ticket.title }
client.organizations.search('zammad').first(10)
```

Zammad's index endpoints do not filter; only the search endpoints do. That is why a
collection has no `where`. `users`, `organizations`, `tickets` and `groups` can be
searched. On the others `search` raises `ZammadAPI::Error`, so use `find_by` or `select`:

```ruby
client.ticket_states.find_by(name: 'open')
client.ticket_priorities.select { it.active }
```

Keywords are passed on to the search endpoint as query parameters: `condition:` and `ids:`
on every search, and `role_ids:`, `group_ids:` and `permissions:` on users. Zammad ignores
a parameter it does not read.

```ruby
client.users.search('smith', role_ids: [2])
client.tickets.search('printer', condition: {'ticket.group_id' => {operator: 'is', value: [2]}})
```

A blank term raises `ArgumentError`. `search('*')` asks for every record.

### Sorting

`order` sorts on the server:

```ruby
client.groups.order(:name)                 # ascending
client.organizations.order(name: :desc)
client.groups.order(:active, name: :desc)  # by active, then by name descending
```

`/api/v1/tickets` and `/api/v1/users` are always served in id order, so `order` on
`client.tickets` or `client.users` raises `ArgumentError`. Sort a search instead:

```ruby
client.tickets.search('state.name:open').order(created_at: :desc)
```

### Pages

```ruby
client.tickets.page(2)                 # page 2 at the size the endpoint serves
client.tickets.page(2, per_page: 10)   # records 11 to 20
```

By default a request asks for the largest page the endpoint serves: 100 for tickets, 200
for a search, 1000 elsewhere. Pass a smaller size with `find_each(batch_size:)`,
`in_batches(of:)` or `page(n, per_page:)`; a larger one is capped.

Collections are immutable: `order` and `page` return a new collection.

### Counting

`count` on a search is one request. Every other collection is read page by page, because
an index endpoint reports no total:

```ruby
client.tickets.search('state.name:open').count    # one request
client.tickets.count                              # one request per page
client.tickets.search('state.name:merged').empty? # one request, for one record
```

## Acting on behalf of another user

Zammad can perform
[actions on behalf of another user](https://docs.zammad.org/en/latest/api/intro.html#actions-on-behalf-of-other-users).
`on_behalf_of` returns a new client:

```ruby
support = client.on_behalf_of('agent@example.com')
support.tickets.create(title: 'Help', group: 'Users', customer_id: 1)
```

Or scoped to a block:

```ruby
client.on_behalf_of('agent@example.com') do |scoped|
  scoped.tickets.find(1)
end
```

The identifier can be a login, an email address or a user id. A `nil` or blank identifier
raises `ArgumentError`. This sends the HTTP `From` header and requires Zammad 5.0 or later.

## Error handling

```ruby
begin
  client.tickets.find(1)
rescue ZammadAPI::NotFoundError
  nil
rescue ZammadAPI::RateLimitError => e
  # The client already waited and retried, so this limit outlasted that.
  reschedule(in: e.retry_after || 60)
rescue ZammadAPI::ResponseError => e
  warn "#{e.status}: #{e.server_message}"
  warn e.body.inspect
end
```

`save` and `update` return `false` on a 422 instead of raising; see
[Saving and validation failures](#saving-and-validation-failures).

Every error descends from `ZammadAPI::Error`:

```text
ZammadAPI::Error
├── ZammadAPI::ConfigurationError    invalid client options
├── ZammadAPI::UnknownResourceError  no such resource, e.g. client.unicorn
├── ZammadAPI::ParseError            unexpected response shape
├── ZammadAPI::PaginationError       endpoint ignored the page parameter
├── ZammadAPI::TransportError
│   ├── ZammadAPI::ConnectionError   unreachable host, TLS failure or open_timeout
│   └── ZammadAPI::TimeoutError      exceeded timeout
└── ZammadAPI::ResponseError         carries the HTTP response
    ├── ZammadAPI::ClientError       4xx
    │   ├── ZammadAPI::AuthenticationError  401
    │   ├── ZammadAPI::AuthorizationError   403
    │   ├── ZammadAPI::NotFoundError        404
    │   ├── ZammadAPI::ValidationError      422
    │   └── ZammadAPI::RateLimitError       429
    └── ZammadAPI::ServerError       5xx
```

`ResponseError` exposes `response` (a `ZammadAPI::Response`) and, as shortcuts, `status`,
`body`, `headers` and `server_message`, plus `operation` and `resource_class`.

A `TransportError` is a request with no answer, which is not the same as one Zammad never
saw: a write that timed out may have been applied.

### Timeouts and retries

A `GET` is retried on connection failures, timeouts and the statuses 429, 500, 502, 503
and 504, with exponential backoff. A write is never retried. Both are options:

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'token',
  timeout:    10,
  retries:    5
)
```

A `Retry-After` header is honoured up to `timeout` seconds. A longer one is not waited
out: the request fails at once, and `RateLimitError#retry_after` carries the figure.

A write that fails raises, because repeating it could create a second record or send an
e-mail twice. The calling code decides whether to send it again:

```ruby
begin
  ticket.update!(state: 'closed')
rescue ZammadAPI::TransportError, ZammadAPI::ServerError
  ticket.reload              # did it arrive?
  retry if ticket.state != 'closed'
end
```

## Logging

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'token',
  logger:     Logger.new($stdout)
)
```

Requests, response statuses and durations are logged at `debug` level. Anything that
responds to `debug` works in place of a `Logger`. Payload keys, query parameters and
headers that look like credentials (`password`, `token`, `secret`, `cookie`, ...) are
redacted, and a path is logged without its query string.

## Endpoints this gem does not model

### Declaring a resource

For an endpoint that serves records like the modelled ones (an index, and a member under
its id), declare a class with a path. `client.resource` then works like `client.tickets`:

```ruby
class Role < ZammadAPI::Resources::Base
  path 'api/v1/roles'
end

roles = client.resource(Role)

roles.each { |role| puts role.name }
roles.find(2).update(note: 'Reviewed')
roles.create(name: 'Auditor')
roles.find_by(name: 'Agent')
```

Declare where the endpoint differs from the defaults:

| Declaration        | Default    | Says                                                          |
| ------------------ | ---------- | ------------------------------------------------------------- |
| `path '…'`         | *required* | The index endpoint, relative to the instance URL.             |
| `searchable true`  | `false`    | Zammad routes `<path>/search`, so `search` works and `find_by` uses it. |
| `max_per_page 100` | `1000`     | The largest page the index endpoint serves.                   |
| `sortable false`   | `true`     | The index endpoint is always served in the same order, so `order` refuses it. |

A subclass of a modelled resource works too, and inherits what its parent declares:
`class MyTicket < ZammadAPI::Resources::Ticket`.

For an endpoint that ignores `page` and returns everything at once, or one that is an
action, a report or a setting, use a raw request.

### Raw requests

`get`, `post`, `put` and `delete` reach any endpoint of the Zammad API, with the same
authentication, timeouts, retries and error classes:

```ruby
client.get('api/v1/roles').body
# => [{id: 1, name: "Admin", ...}, ...]

client.post('api/v1/tags/add', query: {object: 'Ticket', o_id: 1, item: 'urgent'})
client.put('api/v1/roles/2', body: {note: 'Updated'})
client.delete('api/v1/tags/remove', query: {object: 'Ticket', o_id: 1, item: 'urgent'})

client.get('api/v1/tickets/1', headers: {'Accept-Language' => 'de-de'})
```

A `body:` is sent as JSON, and a String body is sent as it is. Each call returns a
`ZammadAPI::Response`:

```ruby
response = client.get('api/v1/tickets')
response.status              # => 200
response.headers['content-type']
response.body                # decoded JSON, or the raw body for anything else
response.raw_body            # the body as it arrived
```

Paths are relative to the instance URL, and a leading slash is ignored. A path that opens
with a scheme, such as `https://other.example/collect`, raises `ArgumentError`, so the
client's credentials only go to the instance it was configured for.

### Coverage

Modelled: tickets, ticket articles and their attachments, ticket states and priorities,
users, organizations and groups, the same set as 1.x.

Not modelled yet: text modules; ticket tags, links, mentions, time accounting, checklists,
shared drafts, merge and history; the knowledge base; global search; CSV imports. Declare
a resource or use raw requests for those, and
[open an issue](https://github.com/zammad/zammad-api-client-ruby/issues/new) for the one
you need, so we know what to model first.

The [features roadmap](ROADMAP.md) shows what is in progress for 2.0, beside 1.x and the
PHP client.

## Adapter and middleware

The client is built on Faraday. `adapter:` picks the Faraday adapter, and `middleware:`
adds your own middleware, such as instrumentation or a cache:

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'token',
  adapter:    :net_http_persistent,
  middleware: ->(connection) { connection.use(MyInstrumentation) }
)
```

To pass arguments to an adapter, set it inside the callable:
`->(connection) { connection.adapter :net_http_persistent, pool_size: 5 }`. Do not add
`response :json` or `response :raise_error`; the client decodes JSON and maps errors
itself.

Faraday's default adapter opens a connection per request. For anything that reads many
pages, downloads attachments in a loop or runs a worker pool, add
`faraday-net_http_persistent` to your Gemfile and pass `adapter: :net_http_persistent`.

## Type signatures

RBS signatures ship in `sig/` and are checked in CI with [Steep](https://github.com/soutaro/steep).
Add the gem to your own RBS collection to type-check calls into this client. Records are
typed, not only the client:

```ruby
ticket = client.tickets.find(1)

ticket.title           # String
ticket.organization_id # Integer?
ticket.titel           # a type error: no such attribute is declared
```

Attributes an administrator added, columns only newer Zammad versions serve, and expanded
association names that can be absent (such as `organization`) are not declared. Read those
with `ticket[:name]`, or reopen the class in your own signatures:

```rbs
class ZammadAPI::Resources::Ticket
  attr_accessor escalation_reason: String?
end
```

A resource of your own needs an annotation:

```ruby
roles = client.resource(Role) #: ZammadAPI::ResourceProxy[Role]
```

## Examples

Runnable scripts covering pagination, pattern matching, acting on behalf of a user,
attachments, error handling and threaded use live in [`examples/`](examples/README.md).

## Development

```sh
bin/setup            # bundle install, plus the overcommit git hooks
bundle exec rake     # unit specs, RuboCop, Steep and the shipped signatures
```

Integration specs need a disposable Zammad named by `TEST_URL`; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Upgrading from 1.x

Most code needs one rename: `client.ticket` is `client.tickets`. Nearly everything else
that changed raises at the call site. [UPGRADING.md](UPGRADING.md) lists every change, and
says how to stay on 1.x.

## License

Dual licensed under the [AGPL-3.0-only](LICENSE.AGPL.txt) or [MIT](LICENSE.MIT.txt)
licenses. See [LICENSE.md](LICENSE.md).
