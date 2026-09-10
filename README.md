# Zammad API Client (Ruby)

[![Gem Version](https://badge.fury.io/rb/zammad_api.svg)](https://badge.fury.io/rb/zammad_api)
[![CI](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml)

Ruby client for the Zammad API v1.0.

- Requires **Ruby 3.4** or later.
- Ships **RBS signatures** in `sig/`, so typed projects get completion and checking out of the box.
- Requests carry **timeouts** and **retry with backoff** for transient failures by default.
- Collections are **lazily paginated** `Enumerable`s, with a familiar
  `where` / `page` / `in_batches` / `find_each` surface.
- Records support **pattern matching**, and clients are **immutable** and safe to share
  between threads.
- **Raw requests** reach the endpoints this gem does not model yet, without giving up
  authentication, retries or the error classes.
- A **test kit** (`zammad_api/test`) stands in for a Zammad, so your own tests need no
  HTTP interception.

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

### From the environment

`from_env` reads `ZAMMAD_URL` and `ZAMMAD_TOKEN` (or `ZAMMAD_USER` and
`ZAMMAD_PASSWORD`, or `ZAMMAD_OAUTH2_TOKEN`), so a script needs no configuration of its
own. Anything passed in wins over the environment:

```ruby
client = ZammadAPI::Client.from_env
client = ZammadAPI::Client.from_env(timeout: 300)
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
| `adapter`        | Faraday's default  | Name of the Faraday adapter to use.                                |
| `middleware`     | `nil`              | Callable that receives the Faraday connection while it is built.   |

Credentials are never written to the log, and `client.config.inspect` redacts them, so a
configuration object is safe to include in an error report.

### Checking the connection

```ruby
client.me.email # => "agent@example.com", the account the credentials belong to
client.version  # => "6.4.0", the Zammad instance's version
```

`client.version` is the version of the Zammad instance; `ZammadAPI::VERSION` is the
version of this gem.

### Adapter and middleware

The HTTP stack is Faraday's, and these two options are the seam into it — for a
persistent-connection adapter, instrumentation, or a cache:

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'token',
  adapter:    :net_http_persistent,
  middleware: ->(connection) { connection.use(MyInstrumentation) }
)
```

The callable runs last, after this gem's own middleware and before the adapter, so it sees
requests as the client finished building them and responses before anything else does.
Faraday stays an implementation detail either way: an unregistered adapter raises
`ZammadAPI::ConfigurationError`, not a Faraday error.

## Available resources

`group`, `organization`, `ticket`, `ticket_article`, `ticket_priority`, `ticket_state`, `user`

`client.resource_names` returns the current list.

Anything not in that list is reachable with [raw requests](#raw-requests).

## Raw requests

`get`, `post`, `put` and `delete` reach any endpoint of the Zammad API, without giving up
authentication, timeouts, retries, credential redaction, JSON decoding or the error
classes. Use them for the endpoints this gem does not model yet.

```ruby
client.get('api/v1/roles').body
# => [{id: 1, name: "Admin", ...}, ...]

client.post('api/v1/tags/add', query: {object: 'Ticket', o_id: 1, item: 'urgent'})
client.put('api/v1/roles/2', body: {note: 'Updated'})
client.delete('api/v1/tags/remove', query: {object: 'Ticket', o_id: 1, item: 'urgent'})
```

Each returns a `ZammadAPI::Response`, so the status and headers stay reachable:

```ruby
response = client.get('api/v1/tickets')
response.status              # => 200
response.headers['x-total-count']
response.body                # decoded JSON, or the raw body for anything else
```

Paths are relative to the instance URL, and a leading slash is ignored, so they can be
pasted straight from the Zammad documentation. A non-2xx response raises the same error
class it would raise for a modelled resource, and `POST` is not retried.

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
group.to_h       # every attribute, as a Hash you may modify
```

Or by attribute, which asks for a single record rather than a whole page:

```ruby
client.user.find_by(email: 'someone@example.com') # => the record, or nil
client.user.find_by!(email: 'nobody@example.com') # raises NotFoundError
client.group.exists?(42)                          # => true
```

Zammad records can carry administrator-defined custom attributes, so an unknown reader
returns `nil` rather than raising. Use `fetch` when a missing attribute should be an error.

`attributes` and `changes` are deeply frozen, because a record that let you write into
them would report a change it had never staged and would not send:

```ruby
group.attributes[:name] = 'Support 2' # FrozenError
group.name = 'Support 2'              # the way to stage a change
group.to_h                            # a deep copy, yours to modify
```

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

Or in one call:

```ruby
group.update(name: 'Support 2', note: 'Renamed')  # assigns, then saves
group.assign_attributes(name: 'Support 3')        # assigns without saving
```

### Saving and validation failures

`save` returns whether the record was stored, and leaves a rejection in `error`:

```ruby
group = client.group.new(name: '')

if group.save
  puts group.id
else
  warn group.error.server_message # => "Name is required"
end
```

Only a rejection of the attributes (HTTP 422) is reported that way. An expired token, a
missing record or an unreachable instance still raises, because those are not something
the calling code can correct by fixing an attribute.

`save!` and `update!` raise on every failure, including validation, which is what you want
in a script:

```ruby
group.save!               # raises ZammadAPI::ValidationError
group.update!(name: '')   # the same, in one call
```

`client.group.create(...)` uses `save!`, so it raises rather than handing back a record
that looks created but is not. Use `new` plus `save` when you need to branch instead.

### Associations

Zammad expands an association into a name under the plain attribute, so those reads are
already loaded and free:

```ruby
ticket = client.ticket.find(1)

ticket.customer    # => "customer@example.com"
ticket.state       # => "open"
ticket.group       # => "Users"
ticket.customer_id # => 7
```

`related` reaches the whole record behind one of those, which costs a request:

```ruby
ticket.related.customer.firstname     # => "Nicole"
ticket.related.group.note
ticket.related.articles               # => [TicketArticle, ...]
ticket.related.created_by.email

client.user.find(7).related.organization
```

The readers live under `related` rather than on the record so that `ticket.customer` keeps
returning the name it always did — an attribute read that silently became an HTTP request
would be a poor trade. `belongs_to` targets are memoized, and `reload` or a save drops the
memo; `has_many` lists are fetched each call, so an article added in between shows up.
`Ticket.associations` lists what a resource declares.

### Comparing and serializing

A record is the Zammad record it came from, not the object that happens to hold it, so two
records of the same kind carrying the same id are equal. That makes `uniq`, `Set`, `include?`
and records-as-Hash-keys behave:

```ruby
client.ticket.find(1) == client.ticket.find(1)  # => true

[client.ticket.find(1), client.ticket.find(1)].uniq.size # => 1
Set[client.ticket.find(1), client.ticket.find(1)].size   # => 1
seen = { client.ticket.find(1) => :handled }
seen[client.ticket.find(1)]                              # => :handled
```

A record with no id is equal only to itself, because two unsaved records are two records
waiting to be created however alike their attributes are. One consequence: a record's first
save assigns its id and so changes its hash, and a record used as a Hash key before that
save has to be rehashed after it.

`to_json` renders the attributes, so a record can be cached, queued or logged as it stands,
and nests inside a structure being generated:

```ruby
client.group.find(1).to_json          # => "{\"id\":1,\"name\":\"Support\"}"
JSON.generate(group: client.group.find(1))
```

`as_json` returns the same attributes as a Hash, for ActiveSupport and any encoder that
follows its convention.

### Reload and destroy

```ruby
group.reload  # re-reads from Zammad, discarding unsaved changes
group.destroy # => true

client.group.destroy(42) # delete by id, without fetching first
```

## Collections

`all`, `where` and `search` return a lazily paginated `ZammadAPI::Collection`. No request
is made until you iterate, and pages are fetched as needed.

A resource proxy is itself `Enumerable` over `all`, so `.all` is optional:

```ruby
client.ticket.each { |ticket| puts ticket.title }
client.ticket.first(5)
client.ticket.pluck(:title)
client.ticket.find_each(batch_size: 500) { |ticket| archive(ticket) }
```

`find` keeps its own meaning there — `client.ticket.find(1)` is a lookup by id, not
`Enumerable#find`. Use `detect` for the block form.

```ruby
# Walks every page automatically.
client.ticket.all.each do |ticket|
  puts ticket.title
end

# Stops after the first page, because Enumerable stops consuming.
first_five = client.ticket.all.first(5)

# Lazy chains work as expected.
client.ticket.all.lazy.select { |t| t.state == 'open' }.first(10)

# One array of records per request, e.g. for a bulk import.
client.ticket.all.in_batches(of: 500) do |tickets|
  import(tickets)
end

# Record by record, with the page size set inline.
client.ticket.all.find_each(batch_size: 500) do |ticket|
  archive(ticket)
end
```

### Filters

```ruby
client.ticket.where(state: 'open').first(10)   # a filtered collection
client.group.all.where(active: true)           # the same, from an existing collection
```

`where` takes Zammad query parameters, such as `sort_by` where the endpoint supports it.
Paging is not one of them: that is what `page`, `in_batches` and `find_each` are for, and passing `page:` or
`per_page:` to `where` raises `ArgumentError` rather than being silently ignored.

### Search

```ruby
client.organization.search('zammad').each do |organization|
  puts organization.name
end
```

### Explicit pages

```ruby
tickets = client.ticket.all

tickets.page(2)           # page 2 of the default 100 per page
tickets.page(2, of: 10)   # records 11 to 20
```

Collections are immutable: `where` and `page` return a new collection and leave the
original untouched.

### Page size

A request fetches 100 records by default. Three calls take another size, each for its own
kind of work:

```ruby
client.ticket.all.find_each(batch_size: 500) { |ticket| archive(ticket) }  # walking
client.ticket.all.in_batches(of: 500) { |tickets| import(tickets) }        # batching
client.ticket.all.page(2, of: 500)                                         # one page
```

`find_each` without a block is an Enumerator, so it is also how you read at a chosen page
size: `client.ticket.all.find_each(batch_size: 500).first(7)`.

Zammad caps the page size per endpoint — 100 for `/api/v1/tickets`, 200 for a search, 1000
for the other index endpoints — and a larger size is reduced to what the endpoint serves.
That keeps a walk complete: a page size the server silently shrank would otherwise end the
iteration at the first page.

### Reading single attributes

```ruby
client.user.all.pluck(:email)        # => ["a@example.com", ...]
client.ticket.all.pluck(:id, :title) # => [[1, "Help"], ...]
```

Zammad cannot be asked for a subset of the fields, so this shapes the result rather than
shrinking the request.

### Counting

`count` walks the pages, except on a search, which Zammad can count in a single request:

```ruby
client.ticket.search('state.name:open').count   # one request
client.ticket.all.count                         # one request per page of 100
```

`size` and `length` are `count`, and cost the same. `empty?` asks for a single record
rather than a page:

```ruby
client.ticket.where(state: 'merged').empty? # one request, for one record
client.group.all.size                       # => 12
```

Nothing is cached, so every traversal of a collection fetches again.

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

```text
ZammadAPI::Error
├── ZammadAPI::ConfigurationError    invalid client options
├── ZammadAPI::UnknownResourceError  no such resource, e.g. client.unicorn
├── ZammadAPI::ParseError            unexpected response shape
├── ZammadAPI::PaginationError       endpoint ignored the page parameter
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

## Testing code that uses this client

`zammad_api/test` ships a stand-in Zammad, so your own tests need no HTTP interception:

```ruby
require 'zammad_api/test'

RSpec.describe TicketCloser do
  let(:zammad) { ZammadAPI::Test.new }

  it 'closes the ticket' do
    zammad.stub(:get, 'api/v1/tickets/1', body: {id: 1, title: 'Help', state: 'open'})
    zammad.stub(:put, 'api/v1/tickets/1', body: {id: 1, state: 'closed'})

    described_class.new(zammad.client).close(1)

    expect(zammad.requests.last.verb).to eq(:put)
    expect(zammad.requests.last.body).to eq({state: 'closed'})
  end
end
```

`zammad.client` is a real `ZammadAPI::Client`, so responses come back through the same
decoding, error mapping and record building as real ones — a stub with `status: 404`
raises `NotFoundError`, and one with `status: 422` makes `save` return `false`.

| Method | What it does |
| ------ | ------------ |
| `stub(verb, path, status:, body:, headers:, query:)` | Declares a response. Stubbing the same endpoint twice describes a sequence; the last stub answers every later request. `query:` matches a subset, so it need not repeat `expand`, `page` or `per_page`. |
| `client` | A client wired to this stand-in. |
| `requests` | Every request made, oldest first, as `verb` / `path` / `query` / `body` / `on_behalf_of`. |
| `reset` | Forgets the stubs and the recorded requests. |

A request that was not stubbed raises `ZammadAPI::Test::UnstubbedRequestError`, listing
what is stubbed, rather than answering with something empty.

## Type signatures

RBS signatures ship in `sig/` and are checked in CI with [Steep](https://github.com/soutaro/steep).
Add the gem to your own RBS collection to type-check calls into this client.

## Examples

Runnable scripts covering pagination, pattern matching, acting on behalf of a user,
attachments, error handling and threaded use live in [`examples/`](examples/README.md).

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
| `collection.page(1, 3) { \|r\| ... }`  | `collection.page(1, of: 3).each { ... }`         | `page` now returns a collection instead of mutating and yielding    |
| `collection.page_next` / `page_prev`   | `collection.page(n)` or `in_batches`             | Removed; they mutated shared state                                  |
| `client.x.all(per_page: 50)`           | `client.x.all.page(1, of: 50)`, `find_each(batch_size: 50)` | Page size belongs to the call that reads, not to every entry point  |
| `client.x.all(active: true)`           | `client.x.where(active: true)`                   | Filters no longer share a keyword bag with the paging parameters    |
| `client.x.search(query: 'zammad')`     | `client.x.search('zammad')`                      | The search term is the argument, not a keyword                      |
| `collection.each_page { ... }`         | `collection.in_batches { ... }`                  | Ruby already has a name for this                                    |
| `collection[3]`                        | `collection.page(4, of: 1).first`                | An index that costs a request, and that ignored `page`, was a trap  |
| `record.save` raised on a rejection    | `save` → `false` with `record.error`; `save!` raises | Branching on a rejected attribute needed a begin/rescue         |
| `record.attributes[:x] = 1`            | `record.x = 1`, or `record.to_h` for a copy      | Writing through the reader staged no change, so `save` never sent it |
| `client.user.find(ticket.customer_id)` | `ticket.related.customer`                        | Following a foreign key needed the client threaded through          |
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

Unchanged: `client.<resource>.find/all/create/new`, `record.destroy`, attribute readers
and writers, `ticket.articles`, `ticket.article`, and `attachment.download`.

`record.save`, `record.changes` and `record.attributes` still exist and still mean what
they meant; only the three rows above change how they behave at the edges.

## License

Dual licensed under the [AGPL-3.0-only](LICENSE.AGPL.txt) or [MIT](LICENSE.MIT.txt)
licenses. See [LICENSE.md](LICENSE.md).
