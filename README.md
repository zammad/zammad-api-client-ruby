# Zammad API Client (Ruby)

[![Gem Version](https://badge.fury.io/rb/zammad_api.svg)](https://badge.fury.io/rb/zammad_api)
[![CI](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/zammad/zammad-api-client-ruby/actions/workflows/ci.yml)

---

> [!IMPORTANT]
> ## 📣 2.0 is taking shape — tell us what you think
>
> **Version 2.0 is a breaking release, and it is not finished yet: this is `2.0.0.alpha1`,
> its first prerelease.** This is the moment when your feedback can still change it: names,
> defaults, what is missing, what reads wrong, and anything that makes upgrading from 1.x
> harder than it should be.
>
> **[→ Open an issue and tell us](https://github.com/zammad/zammad-api-client-ruby/issues/new)**
>
> Especially useful to hear:
>
> - Which 1.x calls in **your** code the [migration table](#migrating-from-1x) does not cover.
> - Endpoints you reach with [raw requests](#raw-requests) that should be modelled resources.
> - Anything the [test kit](#testing-code-that-uses-this-client) cannot stand in for.
> - Naming that made you look twice, and defaults you had to override every time.
>
> Rough notes are welcome — a half-formed "this felt off" is worth more to us now than a
> polished report after the release.

---

Ruby client for the Zammad API v1.0.

- Requires **Ruby 3.4** or later.
- Ships **RBS signatures** in `sig/`, so typed projects get completion and checking out of the box.
- Requests carry **timeouts** and **retry with backoff** for transient failures by default.
- Collections are **lazily paginated** `Enumerable`s, with a familiar
  `order` / `page` / `in_batches` / `find_each` surface.
- Records support **pattern matching**, and clients are **immutable** and safe to share
  between threads.
- **Your own resources** — `client.resource(Role)` gives a class you declare everything a
  modelled one has — and **raw requests** reach the rest of the API, without giving up
  authentication, retries or the error classes.
- A **test kit** (`zammad_api/test`) stands in for a Zammad, so your own tests need no
  HTTP interception.

> **Upgrading from 1.x?** See [Migrating from 1.x](#migrating-from-1x), which lists every
> call that changed.
>
> **Staying on 1.x?** See [Staying on 1.x](#staying-on-1x) for where its code lives and how
> to install it.

## Installation

2.0 is a prerelease for now, `2.0.0.alpha1`, and a prerelease has to be asked for:

```ruby
gem 'zammad_api', '~> 2.0.0.alpha'
```

Or:

```sh
gem install zammad_api --pre
```

`'~> 2.0'` does not match an alpha, and `gem install zammad_api` without `--pre` installs
1.x.

### Staying on 1.x

1.x stays available for a project that is not ready for 2.0, or that runs on a Ruby older
than 3.4: 1.x needs Ruby 3.0 or later.

Its code lives on the
[`1-stable`](https://github.com/zammad/zammad-api-client-ruby/tree/1-stable) branch, and
the [README there](https://github.com/zammad/zammad-api-client-ruby/blob/1-stable/README.md)
documents the 1.x API. To install it, keep the version below 2:

```ruby
gem 'zammad_api', '~> 1.4'
```

Or:

```sh
gem install zammad_api -v '~> 1.4'
```

1.x is in maintenance mode, and will stay there for the foreseeable future: it still gets
fixes, while new features go into 2.0 only. Report a 1.x problem in the same
[issue tracker](https://github.com/zammad/zammad-api-client-ruby/issues), naming the
version, and open a pull request for it against `1-stable`.

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

A client authenticates one way. Passing more than one of these — a token beside a user and
password, say — raises `ZammadAPI::ConfigurationError` rather than quietly sending one of
them.

### From the environment

`from_env` reads `ZAMMAD_URL` and `ZAMMAD_TOKEN` (or `ZAMMAD_OAUTH2_TOKEN`, or
`ZAMMAD_USER` and `ZAMMAD_PASSWORD`), so a script needs no
configuration of its own. A variable that is empty or blank counts as unset. Anything
passed in wins over the environment, and credentials passed in replace the ones the
environment holds:

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
| `timeout`        | `60`               | Seconds to wait for a response. A positive number.                 |
| `open_timeout`   | `10`               | Seconds to wait for the connection. A positive number.             |
| `retries`        | `2`                | Retry attempts for a `GET` that failed transiently. `0` disables retrying. |
| `retry_interval` | `0.5`              | Seconds before the first retry; doubles on each attempt, up to `timeout`. Up to half of it is added to each wait as jitter. |
| `ssl_verify`     | `true`             | Set to `false` only against a server with a self-signed certificate. |
| `proxy`          | `nil`              | Proxy URL.                                                         |
| `user_agent`     | `zammad_api-ruby/<version>` | Value of the `User-Agent` header.                         |
| `logger`         | discards output    | Any `Logger`; the client logs requests and responses at `debug`.    |
| `adapter`        | Faraday's default  | Name of a Faraday adapter, such as `:net_http_persistent`.         |
| `middleware`     | `nil`              | Callable that is handed the Faraday connection while it is built, after this gem's own middleware and the adapter. |

Credentials are never written to the log, and `client.config` redacts them however it is
printed — `inspect`, `to_s` or `pp`, which is what a console shows.

Credentials belong in the options above, not in the URL: `https://user:secret@host/`
raises `ZammadAPI::ConfigurationError`.

### Checking the connection

```ruby
client.me.email # => "agent@example.com", the account the credentials belong to
client.version  # => "6.4.0", the Zammad instance's version, for an administrator
```

`client.me` answers for any account, so it is the check that the client can reach Zammad
and authenticate. `client.version` is the version of the Zammad instance, and Zammad serves
it to administrators only: with an agent's or a customer's credentials it raises
`ZammadAPI::AuthorizationError`. `ZammadAPI::VERSION` is the version of this gem.

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

The adapter is set first, and the callable runs after it, behind this gem's own
middleware, so it sees requests as the client finished building them and responses before
the client does. An adapter that needs arguments is set inside the callable, and takes the
place of one named with `adapter:`:

```ruby
client = ZammadAPI::Client.new(
  url:        'https://zammad.example.com/',
  http_token: 'token',
  middleware: ->(connection) { connection.adapter :net_http_persistent, pool_size: 5 }
)
```

A Faraday error while the connection is built, such as an adapter that is not registered,
raises `ZammadAPI::ConfigurationError`. This gem decodes JSON and maps error statuses
itself, so leave out middleware that does either, such as `response :json` or
`response :raise_error`.

Faraday's default adapter, `net_http`, opens and closes a connection around every
request, so a walk of N pages is N TCP connections and N TLS handshakes. For anything that
pages, downloads attachments in a loop, or runs a worker pool, add
`faraday-net_http_persistent` to your Gemfile and pass `adapter: :net_http_persistent` as
above.

## Available resources

`groups`, `organizations`, `tickets`, `ticket_articles`, `ticket_priorities`,
`ticket_states`, `users`

`client.resource_names` returns the current list.

The names are plural because what each one hands back stands for every record of its kind:
`client.tickets.each` walks them all, and `client.tickets.find(1)` picks one out. The
singular names from 1.x — `client.ticket` and the rest — are gone and raise
`UnknownResourceError`; see [Migrating from 1.x](#the-client).

Anything not in that list is reachable by [declaring a resource](#resources-this-gem-does-not-model)
for it, or with [raw requests](#raw-requests).

### Coverage

What each major version of this gem models, set against what Zammad's API serves. A check
is a class or a method of the gem's own; an empty box is something 2.0 does not model yet.

|                                                  | 1.x | 2.0 |
| ------------------------------------------------ | :-: | :-: |
| **Records**                                      |     |     |
| Tickets                                          | ✅  | ✅  |
| Ticket articles                                  | ✅  | ✅  |
| Article attachments                              | ✅  | ✅  |
| Ticket states                                    | ✅  | ✅  |
| Ticket priorities                                | ✅  | ✅  |
| Users                                            | ✅  | ✅  |
| Organizations                                    | ✅  | ✅  |
| Groups                                           | ✅  | ✅  |
| Text modules                                     |     | ⬜  |
| **Ticket features**                              |     |     |
| Tags                                             |     | ⬜  |
| Links                                            |     | ⬜  |
| Mentions                                         |     | ⬜  |
| Time accounting                                  |     | ⬜  |
| Checklists                                       |     | ⬜  |
| Shared drafts                                    |     | ⬜  |
| Merge                                            |     | ⬜  |
| History                                          |     | ⬜  |
| **Knowledge base**                               |     |     |
| Knowledge bases                                  |     | ⬜  |
| Categories                                       |     | ⬜  |
| Answers, and publishing them                     |     | ⬜  |
| Answer attachments                               |     | ⬜  |
| Search                                           |     | ⬜  |
| **Across resources**                             |     |     |
| Global search                                    |     | ⬜  |
| CSV imports (users, organizations, text modules) |     | ⬜  |

An empty box in the 2.0 column is not out of reach: [declare a resource](#resources-this-gem-does-not-model)
for an endpoint that serves records, or use [raw requests](#raw-requests) for one that does
not. The empty boxes are also where this gem grows next —
[open an issue](https://github.com/zammad/zammad-api-client-ruby/issues/new) for the one
you need, so we know what to model first.

### Resources this gem does not model

A resource is a class with a path. Declare one for an endpoint that serves records the way
the modelled ones do — an index, and a member under its id — and `client.resource` hands
you the same thing `client.tickets` is:

```ruby
class Role < ZammadAPI::Resources::Base
  path 'api/v1/roles'
end

roles = client.resource(Role)

roles.each { |role| puts role.name }        # paginated, like any other
roles.find(2).update(note: 'Reviewed')      # change tracking and save
roles.create(name: 'Auditor')
roles.find_by(name: 'Agent')
```

Say what else is true of the endpoint, where it differs from the defaults:

| Declaration        | Default | Says                                                                 |
| ------------------ | ------- | -------------------------------------------------------------------- |
| `path '…'`         | *required* | The index endpoint, relative to the instance URL.                 |
| `searchable true`  | `false` | Zammad routes `<path>/search`, so `search` works and `find_by` uses it. |
| `max_per_page 100` | `1000`  | The largest page the index endpoint serves. A walk ends at the first page shorter than the size it asked for, so this has to be what the endpoint really serves. |
| `sortable false`   | `true`  | The index endpoint is always served in the same order, so `order` refuses it. |
| `paginated false`  | `true`  | The index endpoint serves every record in one response and reads no `page`. It is read in one request, and `page` refuses it. |
| `belongs_to :role, class_name: 'Role'` | — | A foreign key, read as a record through `record.related.role`. |
| `has_many :members, class_name: 'User', path: ->(id) { "…/#{id}" }` | — | A list served whole by an endpoint of its own. |

`class_name` is a resource of this gem by its own name, `'User'`, or a class of yours by its
full name, `'Acme::Role'`. A subclass of a modelled resource works too, and inherits what
its parent declares: `class MyTicket < ZammadAPI::Resources::Ticket`.

An endpoint that serves every record in one response and ignores `page` —
`api/v1/object_manager_attributes` is one — answers the request for a second page with the
first again, which a walk reports as `ZammadAPI::PaginationError`. Declare such a resource
`paginated false`, and it is read in one request:

```ruby
class ObjectAttribute < ZammadAPI::Resources::Base
  path 'api/v1/object_manager_attributes'
  paginated false
  sortable false
end

client.resource(ObjectAttribute).find_by(name: 'priority_id')   # one request
```

This endpoint sorts nothing either, so it says `sortable false` as well. A search always
pages, whatever the index beside it does.

Use raw requests for an endpoint that is not shaped like that — an action, a report, a
setting.

## Raw requests

`get`, `post`, `put` and `delete` reach any endpoint of the Zammad API, without giving up
authentication, timeouts, retries, credential redaction, JSON decoding or the error
classes. Use them for the endpoints that are not a list of records, and for a one-off call
to one that is.

```ruby
client.get('api/v1/roles').body
# => [{id: 1, name: "Admin", ...}, ...]

client.post('api/v1/tags/add', query: {object: 'Ticket', o_id: 1, item: 'urgent'})
client.put('api/v1/roles/2', body: {note: 'Updated'})
client.delete('api/v1/tags/remove', query: {object: 'Ticket', o_id: 1, item: 'urgent'})
```

All four take `headers:`, for an endpoint that needs one. Names and values are sent as
text:

```ruby
client.get('api/v1/tickets/1', headers: {'Accept-Language' => 'de-de'})
```

A `body:` is sent as JSON, and a String body is sent as it is. A `query:` Hash is encoded
by Faraday, nested Hashes and lists included.

Each returns a `ZammadAPI::Response`, so the status and headers stay reachable:

```ruby
response = client.get('api/v1/tickets')
response.status              # => 200
response.headers['content-type']
response.body                # decoded JSON, or the raw body for anything else
response.raw_body            # the body as it arrived
```

Zammad reports the size of a result in the body rather than in a header, and only where
you ask for it: `only_total_count=true` or `with_total_count=true` on a `/search`
endpoint. `count` on a search collection uses the first of those.

Paths are relative to the instance URL, and a leading slash is ignored, so they can be
pasted straight from the Zammad documentation. A path that opens with a scheme, such as
`https://other.example/collect`, raises `ArgumentError`, so the client's credentials only
ever go to the instance it was configured for. A non-2xx response raises the same error
class it would raise for a modelled resource, and only a `GET` is retried.

## Working with records

### Create

```ruby
group = client.groups.new(name: 'Support', note: 'Some note')
group.save

group.id   # => 42
group.name # => "Support"
```

Or in one call:

```ruby
group = client.groups.create(name: 'Support', note: 'Some note')
```

Attributes are a Hash, or anything that converts to one with `to_hash`. In a Rails
controller that is the permitted parameters, which `new`, `create`, `update`,
`assign_attributes` and `add_article` take as they are:

```ruby
client.users.create(params.require(:user).permit(:login, :email, :password))
```

### Fetch

```ruby
group = client.groups.find(42)
group.name         # => "Support"
group[:name]       # same, and nil rather than an error when it is absent
group.fetch(:name) # raises KeyError if the attribute is absent
group.key?(:name)  # => true
group.to_h         # every attribute, as a Hash you may modify
```

Or by attribute value:

```ruby
client.users.find_by(email: 'someone@example.com') # => the record, or nil
client.users.find_by!(email: 'nobody@example.com') # raises NotFoundError
client.groups.exists?(42)                          # => true
```

`find_by` answers with the first record that carries all of those values, compared
exactly, and `nil` if it finds none. Zammad's index endpoints cannot filter — see
[Narrowing](#narrowing) — so `find_by` fetches candidates and checks them itself:

```ruby
client.users.find_by(email: 'someone@example.com', active: true) # searches the email, checks both
client.ticket_states.find_by(name: 'open')                       # no search endpoint: walks the list
client.users.find_by(organization_id: 5)                         # no String to search on: walks the index
```

An `id:` is read with `find`, in one request, and `nil` if it names no record. Otherwise,
where the resource has a search endpoint and one of the values is a String, the longest
one is the search term, and the hits are read a page at a time until one carries every
value. Otherwise the index is walked until a record matches, which against every user or
ticket on an instance is a request per page.

What a search can find is up to Zammad. With Elasticsearch the term is looked for in
everything a record is indexed with; without it, Zammad reads the string columns of a
user, organization or group, and the title, number and articles of a ticket. On such an
instance `client.tickets.find_by(state: 'open')` answers `nil` for tickets that exist, and
`find_by(...) || create(...)` can create a duplicate. Walk the index where that matters:
`client.tickets.detect { it[:state] == 'open' }`.

Zammad records can carry administrator-defined custom attributes, so readers are resolved
against the attributes the record arrived with rather than declared ahead of time. A reader
for an attribute the record does not carry raises `NoMethodError` rather than answering
`nil`:

```ruby
group.titel              # NoMethodError: undefined method 'titel' for an instance of ...
group[:titel]            # => nil
group.fetch(:titel, nil) # => nil
group.key?(:titel)       # => false
```

Zammad also serves a reduced object where the authenticated user may not see the whole
record, so an attribute that exists in Zammad can be missing here. Use `[]`, `fetch` with a
default, or `key?` wherever an attribute may legitimately be absent.

`attributes` and `changes` are deeply frozen. An attribute writer is the way to stage a
change, and `to_h` is a copy you may modify:

```ruby
group.attributes[:name] = 'Support 2' # FrozenError
group.name = 'Support 2'              # the way to stage a change
group.to_h                            # a deep copy, yours to modify
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
group = client.groups.find(42)
group.name = 'Support 2'

group.changed? # => true
group.changes  # => {name: ["Support", "Support 2"]}

group.save     # sends only the changed attributes
```

A `save` on a persisted record with nothing staged sends no request at all and returns
`true`. Zammad applies an empty update, bumping `updated_at` and `updated_by`, so a no-op
save would otherwise rewrite the record's audit trail.

Writing back the value a record was loaded with is not a change, so it stages nothing.
Writing an attribute the record does not carry always is one, even when the value is `nil`.

Or in one call:

```ruby
group.update(name: 'Support 2', note: 'Renamed')  # assigns, then saves
group.assign_attributes(name: 'Support 3')        # assigns without saving
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

Only a rejection of the attributes (HTTP 422) is reported that way. An expired token, a
missing record or an unreachable instance still raises, because those are not something
the calling code can correct by fixing an attribute.

`save!` and `update!` raise on every failure, including validation, which is what you want
in a script:

```ruby
group.save!               # raises ZammadAPI::ValidationError
group.update!(name: '')   # the same, in one call
```

`client.groups.create(...)` uses `save!`, so it raises rather than handing back a record
that looks created but is not. Use `new` plus `save` when you need to branch instead.

### Associations

Zammad expands an association into a name under the plain attribute, so those reads are
already loaded and free:

```ruby
ticket = client.tickets.find(1)

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

client.users.find(7).related.organization
```

A `has_many` reader such as `articles` is read in a single request and comes back as an
Array rather than a paginating collection, because the association endpoints Zammad routes
serve the whole list.

A ticket's articles are also reachable without `related`, and `add_article` writes one:

```ruby
ticket.articles                                              # the same list
ticket.add_article(body: 'Reset link sent.', type: 'note')  # => the created TicketArticle
```

The readers live under `related` rather than on the record so that `ticket.customer` keeps
returning the name it always did — an attribute read that silently became an HTTP request
would be a poor trade. `belongs_to` targets are memoized until the next attribute write,
`reload` or save; `has_many` lists are fetched on each call, so an article added in between
shows up. `Ticket.associations` lists what a resource declares.

### Comparing and serializing

A record is the Zammad record it came from, not the object that happens to hold it, so two
records of the same kind carrying the same id are equal.
That makes `uniq`, `Set`, `include?` and records-as-Hash-keys behave:

```ruby
client.tickets.find(1) == client.tickets.find(1)  # => true

[client.tickets.find(1), client.tickets.find(1)].uniq.size # => 1
```

A record with no id is equal only to itself, because two unsaved records are two records
waiting to be created however alike their attributes are. A record's first save assigns
its id and so changes its hash, and a record used as a Hash key before that save has to be
rehashed after it.

`to_json` renders the attributes, and `as_json` returns them as a Hash:

```ruby
client.groups.find(1).to_json          # => "{\"id\":1,\"name\":\"Support\"}"
JSON.generate(group: client.groups.find(1))
```

### Reload and destroy

```ruby
group.reload  # re-reads from Zammad, discarding unsaved changes
group.destroy # => true

group.destroyed?  # => true
group.persisted?  # => false, so this is not the inverse of new_record?

client.groups.destroy(42) # delete by id, without fetching first
```

## Collections

`all`, `order` and `search` return a lazily paginated `ZammadAPI::Collection`. No request
is made until you iterate, and pages are fetched as needed.

A resource proxy is itself `Enumerable` over `all`, so `.all` is optional:

```ruby
client.tickets.each { |ticket| puts ticket.title }
client.tickets.first(5)
client.tickets.pluck(:title)
client.tickets.find_each(batch_size: 50) { |ticket| archive(ticket) }
```

`find` keeps its own meaning there — `client.tickets.find(1)` is a lookup by id, not
`Enumerable#find`. Use `detect` for the block form.

```ruby
# Walks every page automatically.
client.tickets.all.each do |ticket|
  puts ticket.title
end

# One request, for five records.
first_five = client.tickets.all.first(5)

# Lazy chains stop fetching once they have enough.
client.tickets.all.lazy.select { |t| t.state == 'open' }.first(10)

# One array of records per request, e.g. for a bulk import.
client.tickets.all.in_batches(of: 50) do |tickets|
  import(tickets)
end

# Record by record, with the page size set inline.
client.tickets.all.find_each(batch_size: 50) do |ticket|
  archive(ticket)
end
```

### Sorting

`order` sorts on the server:

```ruby
client.groups.order(:name)                 # ascending
client.organizations.order(name: :desc)
client.groups.order(:active, name: :desc)  # by active, then by name descending
client.tickets.search('state.name:open').order(created_at: :desc)
```

An attribute on its own sorts ascending and a keyword says which way one runs, as in
ActiveRecord. A second `order` sorts within the first, so
`order(:active).order(name: :desc)` is the third line above.

Not every endpoint sorts. `/api/v1/tickets` and `/api/v1/users` are always served in id
order — their controllers hardcode it and drop `sort_by` — so `order` on those raises
`ArgumentError` rather than handing back records it would be calling sorted. A search
sorts for every resource that can be searched:

```ruby
client.tickets.order(:title)
# ArgumentError: api/v1/tickets is always served in the same order and ignores sort_by

client.tickets.search('state.name:open').order(:title)
```

### Narrowing

**Zammad's index endpoints do not filter.** `ApplicationController#model_index_render`
sorts and pages and drops every other parameter. Filtering by an attribute value exists
only on the `/search` endpoints, which is why a collection has no `where`.

Narrow by a value with [`find_by`](#fetch) for one record, or `search` for many:

```ruby
client.users.find_by(email: 'someone@example.com')
client.tickets.search('state.name:open').first(10)
```

`search` passes any keywords on to the search endpoint as query parameters, for what it
narrows by besides the term: `condition:` and `ids:` on every search, and `role_ids:`,
`group_ids:` and `permissions:` on users:

```ruby
client.users.search('smith', role_ids: [2])
client.users.search('smith', group_ids: {1 => ['read']})
client.tickets.search('printer', condition: {'ticket.state_id' => {operator: 'is', value: [1, 2]}})
client.tickets.search('printer', condition: {'ticket.group_id' => {operator: 'is', value: [2]}})
```

Zammad ignores a parameter it does not read, so a misspelled keyword, or a user keyword on
another resource, comes back unnarrowed. Tickets are narrowed by group with a `condition`
on `ticket.group_id`, as above.

`group_ids: [1]` names no access, and Zammad reads that as `full`; a Hash names the access
for each group, as in `group_ids: {1 => ['read']}`. Neither `role_ids:` nor `permissions:`
is an access check: a user matches a role that has been disabled, and a deactivated user
matches as well.

Zammad routes a search endpoint per model, not for every model. `users`, `organizations`,
`tickets` and `groups` have one; `ticket_states`, `ticket_priorities` and `ticket_articles`
do not, and `search` on those raises `ZammadAPI::Error`. `find_by` works on them all the
same, by walking the list:

```ruby
client.ticket_states.find_by(name: 'open')
client.ticket_priorities.select { it.active }
```

### Search

```ruby
client.organizations.search('zammad').each do |organization|
  puts organization.name
end
```

A blank term raises `ArgumentError`: Zammad reads it as no term at all and answers with
every record. `search('*')` asks for every record in so many words.

### Explicit pages

```ruby
tickets = client.tickets.all

tickets.page(2)                 # page 2 at the size the endpoint serves
tickets.page(2, per_page: 10)   # records 11 to 20
```

Collections are immutable: `order` and `page` return a new collection and leave the
original untouched.

### Page size

A request fetches as many records as the endpoint will serve — 100 for `/api/v1/tickets`,
200 for a search, 1000 for the other index endpoints — so a walk spends as few round trips
as it can. Three calls take another size, each for its own kind of work, and a larger one
is reduced to that cap:

```ruby
client.tickets.all.find_each(batch_size: 50) { |ticket| archive(ticket) }  # walking
client.tickets.all.in_batches(of: 50) { |tickets| import(tickets) }        # batching
client.tickets.all.page(2, per_page: 100)                                  # one page
```

`find_each` without a block is an Enumerator, so it is also how you read at a chosen page
size: `client.tickets.all.find_each(batch_size: 50).first(7)`.

A walk of an index ends at the first page that is shorter than the size it asked for. A
search is walked until a page comes back empty, since Zammad leaves a hit whose record is
gone off its page, and a short page can have more hits behind it.

`first` sizes its request to what it was asked for, so the cheap-looking call is cheap:

```ruby
client.tickets.all.first        # one request, for one record
client.tickets.all.first(5)     # one request, for five
```

A collection that `page` already limited keeps its own size.

### Reading single attributes

```ruby
client.users.all.pluck(:email)        # => ["a@example.com", ...]
client.tickets.all.pluck(:id, :title) # => [[1, "Help"], ...]
```

Zammad cannot be asked for a subset of the fields, so this shapes the result rather than
shrinking the request.

### Counting

`count` on a search is one request, which Zammad answers without serving the records.
Every other collection is walked, because an index endpoint has no total to report:

```ruby
client.tickets.search('state.name:open').count   # one request
client.tickets.all.count                         # one request per page
client.tickets.search('state.name:merged').empty? # one request, for one record
```

A block or an argument is `Enumerable#count` counting matches, and walks either way.
Nothing is cached, so every traversal of a collection fetches again.

### `find` is a lookup, not a filter

`find` on a resource takes an id. On a collection it is `Enumerable#find`, which takes a
block, and passing an id there raises `ArgumentError`:

```ruby
client.tickets.find(1)                 # the lookup by id
client.tickets.all.detect { ... }      # the block form
client.tickets.all.find(1)             # ArgumentError
```

## Deriving clients

A client is immutable. `with` returns a new one with some options changed, re-validating
them and carrying over any `on_behalf_of` scope:

```ruby
bulk = client.with(timeout: 300, retries: 5)
bulk.tickets.all.each { |ticket| archive(ticket) }
```

Naming credentials replaces the ones the client has, whichever kind they were, so
`client.with(oauth2_token: '…')` on a client built with an access token authenticates with
the OAuth2 token alone.

Because nothing is mutated after construction, one client — and any client derived from it —
is safe to use from several threads at once.

## Acting on behalf of another user

As described in the [Zammad API documentation](https://docs.zammad.org/en/latest/api/intro.html#actions-on-behalf-of-other-users),
actions can be performed on behalf of another user. `on_behalf_of` returns a **new**
client, so the original is unaffected and both are safe to use concurrently.

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

The identifier can be a login, an email address or a user id. This sends the standard
HTTP `From` header and requires Zammad 5.0 or later.

An identifier that is `nil` or blank raises `ArgumentError`. Zammad reads an empty `From`
header as none at all, so `client.on_behalf_of(user&.login)` with no user would otherwise
perform every request as the account the client authenticates as.

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

`ResponseError` exposes `status`, `body`, `headers`, `server_message`, `operation` and
`resource_class`. A proxy that returns an HTML error page instead of JSON produces a
`ServerError` describing the status, not a JSON parse failure.

A `TransportError` is a request with no answer, which is not the same as one Zammad never
saw: a write that timed out may have been applied.

### Timeouts and retries

A `GET` is retried on connection failures, timeouts and the transient statuses 429, 500,
502, 503 and 504, with exponential backoff.

A `Retry-After` header on one of those responses is honoured: the client waits as long as
the server asked before the next attempt, up to `timeout` seconds. A longer one is not
waited out. The request fails at once with the error for its status, and
`RateLimitError#retry_after` carries the figure, so a job can reschedule itself.

A write is never retried. `POST` would create a second record, and `PUT` and `DELETE` are
not safe to repeat against Zammad either: a ticket update carrying an `article` adds that
article — and sends its e-mail — once per delivery. So a write that fails raises, and the
code that knows what the request carried decides whether to send it again:

```ruby
begin
  ticket.update!(state: 'closed')
rescue ZammadAPI::TransportError, ZammadAPI::ServerError
  ticket.reload              # did it arrive?
  retry if ticket.state != 'closed'
end
```

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

Any object that responds to `debug` will do in place of a `Logger`. Each line is handed
over as a block, so that it is only built where it is written.

Requests, response statuses and durations are logged at `debug` level. Payload keys, query
parameters and headers that look like credentials (`password`, `token`, `secret`, `cookie`,
...) are redacted, and a path is logged without its query string. A body that is not a
Hash or an Array, such as a JSON String, is not logged, only its size.

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
| `stub(verb, path, status:, body:, headers:, query:)` | Declares a response. `query:` matches a subset of the request's parameters, so it need not repeat `expand`, `page` or `per_page`. |
| `client` | A client wired to this stand-in. |
| `requests` | Every request made, oldest first, as `verb` / `path` / `query` / `body` / `headers` / `on_behalf_of`. |
| `stubbed` | One `"GET api/v1/groups"` per stubbed endpoint. |
| `reset` | Forgets the stubs and the recorded requests. |

A `Hash` or `Array` body is served as JSON and gets `content-type: application/json`
unless `headers:` says otherwise, and it is that header that decides whether the body
comes back decoded, as it does on the wire. A recorded request's `query` has its keys and
values as text, and its `headers` have downcased names; the headers the client sets from
its configuration are not in it, and an `on_behalf_of` scope has a field of its own.

Stubbing the same endpoint again queues a second response. A request is answered by the
first stub whose `query:` it matches, and that stub is used up unless it is the last one
that matches, so the last answers every later request:

```ruby
zammad.stub(:get, 'api/v1/groups', body: [{id: 1, name: 'Users'}])
zammad.stub(:get, 'api/v1/groups', body: [{id: 1, name: 'Users'}, {id: 2, name: 'Sales'}])

client.groups.all.count # => 1
client.groups.all.count # => 2
```

One stub is enough for a list. It answers the first page as written, and a request for a
later page with an empty list, unless its `query:` names a `page`:

```ruby
zammad.stub(:get, 'api/v1/groups', body: [{id: 1, name: 'Users'}, {id: 2, name: 'Sales'}])

client.groups.all.map(&:name) # => ["Users", "Sales"]

zammad.stub(:get, 'api/v1/tickets', body: first_hundred, query: {page: 1})
zammad.stub(:get, 'api/v1/tickets', body: [{id: 101}], query: {page: 2})
```

The stand-in does not retry: a stubbed 429 or 5xx raises at once, where a client talking
to Zammad would ask again.

A request that was not stubbed raises `ZammadAPI::Test::UnstubbedRequestError`, listing
what is stubbed, rather than answering with something empty. It is deliberately not a
`ZammadAPI::Error`: a forgotten stub means the test is wrong, not that Zammad refused
something, so a `rescue ZammadAPI::Error` in the code under test lets it through.

## Type signatures

RBS signatures ship in `sig/` and are checked in CI with [Steep](https://github.com/soutaro/steep).
Add the gem to your own RBS collection to type-check calls into this client.

Records are typed, not only the client. `client.tickets` is a
`ResourceProxy[Resources::Ticket]`, so `find`, `first`, `find_by`, the block of `each` and
a search all hand you a `Ticket`, and each resource declares the attributes every
supported Zammad serves for it:

```ruby
ticket = client.tickets.find(1)

ticket.title                   # String
ticket.organization_id         # Integer?
ticket.related.customer&.email # String?
ticket.titel                   # a type error, where it used to be untyped
```

Three things are deliberately not declared, and each has a way through:

- **Attributes an administrator added.** Read one with `ticket[:escalation_reason]`, or
  declare it in your own signatures by reopening the class:

  ```rbs
  class ZammadAPI::Resources::Ticket
    attr_accessor escalation_reason: String?
  end
  ```

- **Columns only newer Zammad versions have**, which an older instance does not serve.
  `record[:name]` reads those too.
- **The name `expand` adds for an association that may be empty**, such as `organization`
  on a ticket or a user. Zammad leaves the key out rather than sending `null`, so a reader
  would raise rather than answer `nil`; `ticket[:organization]` is `nil` in that case, and
  `ticket.organization_id` is always there.

A proxy for [a resource of your own](#resources-this-gem-does-not-model) is untyped until
you say what it holds, because a signature cannot carry a class into its own return type:

```ruby
roles = client.resource(Role) #: ZammadAPI::ResourceProxy[Role]
```

The types describe a record Zammad served. One built with `new` carries only what it was
given until it is saved, and reading anything else from it raises `NoMethodError`, whatever
the signature says the type would be.

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
| `rake steep`             | Type-check `lib/` against `sig/`, and `spec/typed/` the way a caller is checked |

Set `COVERAGE=true` to produce a coverage report in `coverage/`.

### Testing against a live Zammad

The integration specs and `check_connection` need a reachable Zammad instance and **will
create and delete records**, so they run only where `TEST_URL` names one, and there is no
default: point it at something disposable. Without it, `rspec` runs the unit specs and
says the integration specs were left out, `rspec spec/integration` fails for having
nothing to run, and `rake spec:integration`, `rake spec` and `rake check_connection` stop
before running anything.

```sh
export TEST_URL=https://zammad.example/   # a disposable Zammad, never one you keep data in
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
compatibility. Most calling code needs one rename and no more — the resource readers are
plural, so `client.ticket` is `client.tickets` — and almost everything else that needs an
edit raises at the call site. Start with the handful of changes that do not.

If this is not the time to move, [1.x stays available](#staying-on-1x).

### Changes that do not announce themselves

- **`record.attributes = {...}`** was a writer in 1.x. It is now an ordinary attribute
  assignment, so it stages a change named `attributes` and `save` sends it to Zammad:

  ```ruby
  group.attributes = {name: 'Support'}
  group.changes # => {attributes: [nil, {name: "Support"}]}
  ```

  Use `assign_attributes(name: 'Support')`, or `update` to assign and save.

- **`record.save`** returns `false` when Zammad rejects the attributes, where 1.x raised.
  Code that relied on the exception carries on after a rejected save:

  ```ruby
  ticket.state = 'closed'
  ticket.save # false on a 422 in 2.0; nothing raises, and the ticket is still open
  ```

  Check what `save` returns and read `record.error`, or call `save!`, which raises
  `ZammadAPI::ValidationError` as `save` used to. `update` and `update!` are the same pair.

- **`collection.each`** walks every page, where 1.x read one and stopped:
  `client.ticket.all.each { ... }`, as 1.x spelled it, touched the first 100 tickets. That
  line raises in 2.0, because the reader is `client.tickets` now, and renaming it is all it
  takes to run again — after which it touches every ticket the client can read, at a request
  per page. A loop written to handle the first page, or one that writes to each record it is
  handed, does that to all of them now. Limit it explicitly with `first(n)` or
  `page(1, per_page: n)`.

- **A Hash inside an Array attribute** has Symbol keys, where 1.x left it the String keys
  Zammad sent: only a Hash directly under another Hash was symbolized. Read by String key,
  it answers `nil` and nothing raises:

  ```ruby
  article.attributes[:attachments].first['filename'] # the name in 1.x, nil in 2.0
  article.attributes[:attachments].first[:filename]  # the name in 2.0
  ```

  Keys are Symbols at every depth now, so one spelling reads a value wherever it sits.

- **`rescue Faraday::ConnectionFailed`** (and any other Faraday exception) no longer
  matches. Transport failures are wrapped, so rescue `ZammadAPI::ConnectionError`,
  `ZammadAPI::TimeoutError`, or `ZammadAPI::TransportError` for both.

### The client

| 1.x                                    | 2.0                                              | Why                                                                  |
| -------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------- |
| `Client.new(config_hash)`              | `Client.new(**config_hash)`                      | Options are keyword arguments now, so a Hash has to be splatted      |
| an unknown option was ignored          | raises `ArgumentError: unknown keyword`          | A typo'd option used to be dropped without a word                    |
| `logger: true`                         | `logger: Logger.new($stderr)`                    | The flag became an object, so you choose the device and level. Anything that responds to `debug` is accepted; `true` raises `ConfigurationError` |
| `client.ticket`, `client.user`, …      | `client.tickets`, `client.users`, …              | A resource is `Enumerable` over every record now, so `client.ticket.each` read as if it acted on one ticket. The singular names raise `UnknownResourceError`, which lists the plural ones, and so does `client.resource(:ticket)` |
| `client.on_behalf_of = 'login'`        | `client.on_behalf_of('login')` → new client      | The setter mutated the client and leaked across threads              |
| `client.perform_on_behalf_of('x') { }` | `client.on_behalf_of('x') { \|scoped\| ... }`    | The old block form left the header set if the block raised           |
| `ZammadAPI::Resources::Role < Base` reached by `client.role` | `client.resource(Role)`, for a `Role < ZammadAPI::Resources::Base` of your own | The named readers are a fixed list, and a class is handed over rather than looked up by name. [Raw requests](#raw-requests) reach whatever is not a resource |

### Collections

| 1.x                                      | 2.0                                              | Why                                                                 |
| ---------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------- |
| `collection.each` stopped after one page | `each` walks every page                          | Iterating truncated silently at the page size: 100 for `all`, 10 for `search` |
| `collection.page(1, 3) { \|r\| ... }`    | `collection.page(1, per_page: 3).each { ... }`         | `page` now returns a collection instead of mutating and yielding    |
| `collection.page_next` / `page_prev`     | `collection.page(n)` or `in_batches`             | Removed; they mutated shared state                                  |
| `collection[3]`                          | `collection.page(4, per_page: 1).first`                | An index that costs a request, and that ignored `page`, was a trap  |
| `collection.find(1)`                     | `client.x.find(1)`, or `collection.detect { ... }` | On a collection `find` is `Enumerable#find`, whose argument is an ifnone callable — so an id answered with an Enumerator and made no request. It raises now |
| `client.x.all(per_page: 50)`             | `client.x.all.page(1, per_page: 50)`, `find_each(batch_size: 50)` | `all` accepted the argument and discarded it; page size belongs to the call that reads |
| `client.x.all(active: true)`             | `client.x.search(...)`, or `client.x.all.detect { ... }`    | The filter never reached the request in 1.x, and could not have: Zammad's index endpoints do not filter, so 2.0 has no call that pretends to. `find_by(active: true)` answers with the first such record, by walking the index where it has no string to search on |
| `client.x.search(query: 'zammad')`       | `client.x.search('zammad')`                      | The search term is the argument, not a keyword                      |
| `client.x.search(query: 'z', page: 2, per_page: 50)` | `client.x.search('z').page(2, per_page: 50)` | Search did honour those two; paging is the collection's job now     |

### Records

| 1.x                                 | 2.0                                                  | Why                                                                  |
| ----------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------- |
| `record.save` raised on a rejection | `save` → `false` with `record.error`; `save!` raises  | Branching on a rejected attribute needed a begin/rescue              |
| `record.attributes[:x] = 1`         | `record.x = 1`, or `record.to_h` for a copy          | Writing through the reader staged no change, so `save` never sent it  |
| `record.attributes = {...}`         | `record.assign_attributes(...)` / `record.update(...)` | The writer is gone, and the name now stages an attribute of its own |
| `record.id = 5`                     | `client.x.find(5)`                                   | The id addresses the record, so a staged one deleted or updated a different record than it reported. It raises `ZammadAPI::Error` now |
| `record.new_instance`               | `record.new_record?` / `record.persisted?`           | Internal flag is no longer public; the old name raises `NoMethodError` |
| `resource.url` (instance)           | `Resource.resource_path` (class)                     | Clashed with an attribute named `url`                                |
| `record.unknown_attribute` → `nil`  | raises `NoMethodError`; use `record[:x]`, `fetch(:x, nil)` or `key?(:x)` | A typo read as `nil` and flowed on into whatever was written with it. Zammad also serves a reduced object where the user may not see the whole record, and that is worth being told about |
| `client.users.find(ticket.customer_id)` | `ticket.related.customer`                         | Following a foreign key needed the client threaded through           |
| `ticket.article(body: '…')`         | `ticket.add_article(body: '…')`                      | A noun that sends a `POST`, one letter away from `ticket.articles`, which only reads. The method is gone: `article` is an attribute reader like any other, and the old call raises `NoMethodError` |

### Errors

| 1.x                                   | 2.0                                                  | Why                                                             |
| ------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------- |
| `ZammadAPI::Error < RuntimeError`     | `ZammadAPI::Error < StandardError`                   | `RuntimeError` is for `raise "string"`                          |
| `ZammadAPI::ResourceNotFoundError`    | `ZammadAPI::UnknownResourceError`                    | Renamed so it is not confused with a 404, now `NotFoundError`   |
| `ClientError` for every 4xx           | `AuthenticationError`, `NotFoundError`, `ValidationError`, … | All still `ClientError`, so existing rescues keep working |
| a Faraday exception for a dead host   | `ZammadAPI::ConnectionError` / `TimeoutError`        | Every failure this gem can raise descends from `ZammadAPI::Error` |
| `error.response` was a Faraday object | `ZammadAPI::Response` with `status`/`body`/`headers` | Faraday is no longer part of the public surface                 |
| `error.body` was a raw JSON string    | decoded Hash, or the raw body for non-JSON           | Saves every caller from parsing it again                        |

### Removed constants, and the Ruby version

| 1.x                                              | 2.0                        | Why                                                          |
| ------------------------------------------------ | -------------------------- | ------------------------------------------------------------ |
| `ZammadAPI::ListBase` / `ListAll` / `ListSearch` | `ZammadAPI::Collection`    | One class instead of three                                   |
| `ZammadAPI::Dispatcher`                          | `ZammadAPI::ResourceProxy` | Renamed; `client.<resource>` hands you one                   |
| `ZammadAPI::Log`, `ZammadAPI::JsonHelper`        | removed                    | Pass any `Logger` as `logger:`; decoding moved into the transport |
| Ruby >= 3.0                                      | Ruby >= 3.4                | 3.0 through 3.3 are end-of-life or nearly so                 |

### Defaults 1.x did not have

A collection fetches as many records per request as the endpoint serves — 1000 on the index
endpoints, 100 on tickets, 200 on a search — rather than a fixed 100, so a walk spends
roughly a tenth of the round trips. `page(n)` without `per_page:` is a page of that size, so pin
it with `page(n, per_page: 100)` if a persisted page number has to keep meaning what it did.

A request now times out after 60 seconds (10 to connect) where 1.x waited as long as the
server took, so a call that used to hang raises `ZammadAPI::TimeoutError`. A `GET` is
retried twice with exponential backoff on connection failures, timeouts and the transient
statuses, which means a genuinely broken endpoint takes a little longer to report itself;
a `POST`, `PUT` or `DELETE` is never retried. Both are options — see
[Timeouts and retries](#timeouts-and-retries). The `User-Agent` is now
`zammad_api-ruby/<version>` rather than `Zammad API Ruby`.

### What did not change

`find`, `all`, `create` and `new` on a resource, `record.destroy`, attribute readers and
writers, `ticket.articles` and `attachment.download`. The resources themselves are reached
by their plural names — `client.tickets` — and adding an article is `ticket.add_article`;
those two are renames, and the old names raise.

`record.save`, `record.changes` and `record.attributes` still exist and still mean what
they meant; the tables above only change how they behave at the edges.

## License

Dual licensed under the [AGPL-3.0-only](LICENSE.AGPL.txt) or [MIT](LICENSE.MIT.txt)
licenses. See [LICENSE.md](LICENSE.md).
