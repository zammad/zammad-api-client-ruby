# Zammad API Client (Ruby)

[![Gem Version](https://badge.fury.io/rb/zammad_api.svg)](https://badge.fury.io/rb/zammad_api)
[![CI](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml)

Ruby client for the Zammad API v1.0.

- Requires **Ruby 3.4** or later.
- Ships **RBS signatures** in `sig/`, so typed projects get completion and checking out of the box.
- Requests carry **timeouts** and **retry with backoff** for transient failures by default.
- Collections are **lazily paginated** `Enumerable`s.
- Records support **pattern matching**, and clients are **immutable** and safe to share
  between threads.

> **Upgrading from 1.x?** See [Migrating from 1.x](#migrating-from-1x). Version 2.0 is a
> breaking release.

## Installation

```ruby
gem 'zammad_api', '~> 2.0'
```

Or:

```sh
gem install zammad_api
```

## Creating a client

### Access token

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'your-access-token'
)
```

### OAuth2

```ruby
client = ZammadAPI::Client.new(
  url:          'https://zammad.example.com/',
  oauth2_token: 'your-oauth2-token'
)
```

### Username and password

```ruby
client = ZammadAPI::Client.new(
  url:      'https://zammad.example.com/',
  user:     'user@example.com',
  password: 'some_pass'
)
```

### Options

| Option           | Default            | Description                                                        |
| ---------------- | ------------------ | ------------------------------------------------------------------ |
| `url`            | *required*         | Base URL. A sub-path such as `https://example.com/zammad/` works.  |
| `http_token`     | `nil`              | Zammad access token.                                               |
| `oauth2_token`   | `nil`              | OAuth2 bearer token.                                               |
| `user`           | `nil`              | Login for basic authentication.                                    |
| `password`       | `nil`              | Password for basic authentication.                                 |
| `timeout`        | `60`               | Seconds to wait for a response.                                    |
| `open_timeout`   | `10`               | Seconds to wait for the connection.                                |
| `retries`        | `2`                | Retry attempts for idempotent requests. `0` disables retrying.      |
| `retry_interval` | `0.5`              | Seconds before the first retry; doubles on each attempt.           |
| `ssl_verify`     | `true`             | Set to `false` only against a server with a self-signed certificate. |
| `proxy`          | `nil`              | Proxy URL.                                                         |
| `user_agent`     | `zammad_api-ruby/<version>` | Value of the `User-Agent` header.                         |
| `logger`         | discards output    | Any `Logger`; the client logs requests and responses at `debug`.    |

Credentials are never written to the log, and `client.config.inspect` redacts them, so a
configuration object is safe to include in an error report.

## Available resources

`group`, `organization`, `ticket`, `ticket_article`, `ticket_priority`, `ticket_state`, `user`

`client.resource_names` returns the current list.

## Working with records

### Create

```ruby
group = client.group.new(name: 'Support', note: 'Some note')
group.save

group.id   # => 42
group.name # => "Support"
```

Or in one call:

```ruby
group = client.group.create(name: 'Support', note: 'Some note')
```

### Fetch

```ruby
group = client.group.find(42)
group.name       # => "Support"
group[:name]     # same, without method_missing
group.fetch(:name) # raises KeyError if the attribute is absent
group.to_h       # every attribute as a Hash
```

Zammad records can carry administrator-defined custom attributes, so an unknown reader
returns `nil` rather than raising. Use `fetch` when a missing attribute should be an error.

### Pattern matching

Records implement `deconstruct_keys`, so they work with `case/in`:

```ruby
case client.ticket.find(1)
in {state: 'closed'}
  nil
in {state: String => state, priority: '3 high'}
  escalate(state)
in {group: {name: 'Support'}}
  notify_support
end
```

`Config` and `Response` are `Data` objects, so their members match too:

```ruby
case client.config
in {http_token: String}
  :token_auth
in {user: String, password: String}
  warn 'prefer an access token over basic auth'
end
```

### Update

```ruby
group = client.group.find(42)
group.name = 'Support 2'

group.changed? # => true
group.changes  # => {name: ["Support", "Support 2"]}

group.save     # sends only the changed attributes
```

### Reload and destroy

```ruby
group.reload  # re-reads from Zammad, discarding unsaved changes
group.destroy # => true

client.group.destroy(42) # delete by id, without fetching first
```

## Collections

`all` and `search` return a lazily paginated `ZammadAPI::Collection`. No request is made
until you iterate, and pages are fetched as needed.

```ruby
# Walks every page automatically.
client.ticket.all.each do |ticket|
  puts ticket.title
end

# Stops after the first page, because Enumerable stops consuming.
first_five = client.ticket.all.first(5)

# Lazy chains work as expected.
client.ticket.all.lazy.select { |t| t.state == 'open' }.first(10)

# Page at a time, e.g. for bulk import.
client.ticket.all.each_page do |tickets|
  import(tickets)
end
```

### Search

```ruby
client.organization.search(query: 'zammad').each do |organization|
  puts organization.name
end
```

### Explicit pages and filters

```ruby
collection = client.group.all(per_page: 50)

collection.page(2)                  # a new collection limited to page 2
collection.page(2, per_page: 10)    # with a different page size
collection.where(active: true)      # a new collection with extra query params
collection[0]                       # the first record
```

Collections are immutable: `page` and `where` return a new collection and leave the
original untouched.

## Deriving clients

A client is immutable. `with` returns a new one with some options changed, re-validating
them and carrying over any `on_behalf_of` scope:

```ruby
bulk = client.with(timeout: 300, retries: 5)
bulk.ticket.all.each { |ticket| archive(ticket) }
```

Because nothing is mutated after construction, one client — and any client derived from it —
is safe to use from several threads at once.

## Acting on behalf of another user

As described in the [Zammad API documentation](https://docs.zammad.org/en/latest/api/intro.html#actions-on-behalf-of-other-users),
actions can be performed on behalf of another user. `on_behalf_of` returns a **new**
client, so the original is unaffected and both are safe to use concurrently.

```ruby
support = client.on_behalf_of('agent@example.com')
support.ticket.create(title: 'Help', group: 'Users', customer_id: 1)
```

Or scoped to a block:

```ruby
client.on_behalf_of('agent@example.com') do |scoped|
  scoped.ticket.find(1)
end
```

The identifier can be a login, an email address or a user id. This sends the standard
HTTP `From` header and requires Zammad 5.0 or later.

## Error handling

Every error descends from `ZammadAPI::Error`.

```
ZammadAPI::Error
├── ZammadAPI::ConfigurationError    invalid client options
├── ZammadAPI::UnknownResourceError  no such resource, e.g. client.unicorn
├── ZammadAPI::ParseError            unexpected response shape
├── ZammadAPI::TransportError
│   ├── ZammadAPI::ConnectionError   unreachable host or TLS failure
│   └── ZammadAPI::TimeoutError      exceeded timeout or open_timeout
└── ZammadAPI::ResponseError         carries the HTTP response
    ├── ZammadAPI::ClientError       4xx
    │   ├── ZammadAPI::AuthenticationError  401
    │   ├── ZammadAPI::AuthorizationError   403
    │   ├── ZammadAPI::NotFoundError        404
    │   ├── ZammadAPI::ValidationError      422
    │   └── ZammadAPI::RateLimitError       429
    └── ZammadAPI::ServerError       5xx
```

```ruby
begin
  client.ticket.find(1)
rescue ZammadAPI::NotFoundError
  nil
rescue ZammadAPI::RateLimitError => e
  sleep(e.retry_after || 5)
  retry
rescue ZammadAPI::ResponseError => e
  warn "#{e.status}: #{e.server_message}"
  warn e.body.inspect
end
```

`ResponseError` exposes `status`, `body`, `headers`, `server_message`, `operation` and
`resource_class`. A proxy that returns an HTML error page instead of JSON produces a
`ServerError` describing the status, not a JSON parse failure.

### Timeouts and retries

Idempotent requests (`GET`, `PUT`, `DELETE`) are retried on connection failures, timeouts
and the transient statuses 429, 500, 502, 503 and 504, with exponential backoff. `POST` is
never retried, so a failed create cannot silently produce duplicate records.

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'token',
  timeout:    10,
  retries:    5
)
```

## Logging

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'token',
  logger:     Logger.new($stdout)
)
```

Requests, response statuses and durations are logged at `debug` level. Payload keys that
look like credentials (`password`, `token`, `secret`, ...) are redacted.

## Type signatures

RBS signatures ship in `sig/` and are checked in CI with [Steep](https://github.com/soutaro/steep).
Add the gem to your own RBS collection to type-check calls into this client.

## Development

```sh
bin/setup            # or: bundle install
bundle exec rake     # unit specs, RuboCop and Steep
```

| Task                     | What it does                                          |
| ------------------------ | ----------------------------------------------------- |
| `rake spec:unit`         | Unit specs; stubbed, no Zammad needed                 |
| `rake spec:integration`  | Integration specs against a live Zammad               |
| `rake check_connection`  | Drives a live Zammad end to end and prints a transcript |
| `rake rubocop`           | Style checks                                          |
| `rake steep`             | Type-check `lib/` against `sig/`                      |

Set `COVERAGE=true` to produce a coverage report in `coverage/`.

### Testing against a live Zammad

The integration specs and `check_connection` need a reachable Zammad instance and **will
create and delete records**, so point them at something disposable:

```sh
export TEST_URL=http://localhost:3000/
export TEST_USER=admin@example.com
export TEST_PASSWORD=test

bundle exec rake check_connection   # one linear pass, readable transcript
bundle exec rake spec:integration   # the full spec suite
```

`check_connection` walks the documented workflows in order — create, find, update, reload,
pattern match, paginate, search, ticket with articles, attachment download, acting on
behalf of a user, and each error class — printing `ok` or `FAIL` per step and cleaning up
after itself. It stops early if a precondition fails, so a broken instance produces one
clear line rather than a cascade.

CI runs both against a Zammad booted from source: the `integration` job clones Zammad,
starts it, waits for it to answer, runs `check_connection` as a fast preflight, then runs
the integration specs. Trigger it by hand from the Actions tab (`workflow_dispatch`) to
test against a specific Zammad ref.

## Migrating from 1.x

Version 2.0 fixes long-standing behaviour that could not change without breaking
compatibility. Most calling code needs no edits; the table lists everything that does.

| 1.x                                   | 2.0                                              | Why                                                                 |
| ------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------- |
| `collection.each` stopped after one page | `each` walks every page                        | Iterating a collection silently truncated at 100 records            |
| `collection.page(1, 3) { \|r\| ... }`  | `collection.page(1, per_page: 3).each { ... }`   | `page` now returns a collection instead of mutating and yielding    |
| `collection.page_next` / `page_prev`   | `collection.page(n)` or `each_page`              | Removed; they mutated shared state                                  |
| `client.on_behalf_of = 'login'`        | `client.on_behalf_of('login')` → new client      | The setter mutated the client and leaked across threads             |
| `client.perform_on_behalf_of('x') { }` | `client.on_behalf_of('x') { \|scoped\| ... }`    | The old block form left the header set if the block raised          |
| `ZammadAPI::ResourceNotFoundError`     | `ZammadAPI::UnknownResourceError`                | Renamed so it is not confused with a 404, now `NotFoundError`       |
| `ZammadAPI::Error < RuntimeError`      | `ZammadAPI::Error < StandardError`               | `RuntimeError` is for `raise "string"`                              |
| `error.response` was a Faraday object  | `ZammadAPI::Response` with `status`/`body`/`headers` | Faraday is no longer part of the public surface                 |
| `error.body` was a raw JSON string     | decoded Hash, or the raw body for non-JSON       | Saves every caller from parsing it again                            |
| `record.new_instance`                  | `record.new_record?` / `record.persisted?`       | Internal flag is no longer public                                   |
| `resource.url` (instance)              | `Resource.resource_path` (class)                 | Clashed with an attribute named `url`                                |
| `ZammadAPI::ListBase` / `ListAll` / `ListSearch` | `ZammadAPI::Collection`                | One class instead of three                                          |
| `ZammadAPI::Log`, `ZammadAPI::JsonHelper` | removed                                       | Pass any `Logger` as `logger:`; decoding moved into the transport   |
| Ruby >= 3.0                            | Ruby >= 3.4                                      | 3.0 through 3.3 are end-of-life or nearly so                        |

Unchanged: `client.<resource>.find/all/search/create/new`, `record.save`, `record.destroy`,
`record.changes`, `record.attributes`, attribute readers and writers, `ticket.articles`,
`ticket.article`, and `attachment.download`.

## License

Dual licensed under the [AGPL-3.0-only](LICENSE.AGPL.txt) or [MIT](LICENSE.MIT.txt)
licenses. See [LICENSE.md](LICENSE.md).
