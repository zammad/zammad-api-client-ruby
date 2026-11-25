# Changelog

## [2.0.0.alpha1] - 2026-11-17

The first prerelease of 2.0, a breaking release that modernises the whole gem. See
[Migrating from 1.x](README.md#migrating-from-1x) for the complete before/after guide.

Everything below is what changed since 1.4.0. It is published as an alpha so that it can
still change: names, defaults and behaviour may differ in 2.0.0. A prerelease has to be
asked for, with `gem install zammad_api --pre` or `gem 'zammad_api', '~> 2.0.0.alpha'`.

### Breaking

- Minimum Ruby version is now 3.4. 3.0 through 3.2 are end-of-life, and 3.3 is in security
  maintenance until March 2027.
- `Client.new` takes keyword arguments, so a configuration Hash has to be splatted:
  `Client.new(**config)`. A positional Hash raises `ArgumentError`.
- An unknown client option raises `ArgumentError: unknown keyword` instead of being
  ignored.
- `logger:` takes a `Logger` rather than a boolean flag. `logger: true` used to turn on
  debug output to `$stderr`; pass `Logger.new($stderr)` for the same thing. Anything that
  responds to `debug` works.
- `Collection#each` (`client.x.all`, `client.x.search`) now walks every page. Previously it
  fetched a single page, so iterating stopped silently at 100 records for `all` and at
  10 for `search`.
- Collections are built up by chaining instead of by keyword arguments:
  `all(per_page: 50)` is now `find_each(batch_size: 50)` or `page(1, per_page: 50)`,
  `all(active: true)` is `search(...)` or `all.detect { ... }`,
  `search(query: 'zammad')` is `search('zammad')`,
  and `search(query: 'z', page: 2, per_page: 50)` is `search('z').page(2, per_page: 50)`.
  `all` accepted those keywords and then discarded them, so its page size was always
  100 and its filters never reached the request. All of them now raise `ArgumentError`.
- `page(number, per_page)` with a block was replaced by `page(number, per_page: size)`, which
  returns a new collection. `page_next` and `page_prev` were removed.
- `Collection#[]` was removed. It cost a request per index and ignored the page a
  collection was limited to; use `first`, or `page(n, per_page: 1).first` for one record at an
  offset.
- There is no `per`. The page size belongs to the call that reads: `find_each(batch_size:)`
  to walk, `in_batches(of:)` to batch, `page(number, per_page:)` for one page. Everything else
  fetches as many records as the endpoint serves.
- A collection fetches the endpoint's own page size rather than a fixed 100 — 1000 on the
  index endpoints, 100 on `/api/v1/tickets`, 200 on a search. `page(n)` without `per_page:`
  is a page of that size, so pin it with `page(n, per_page: 100)` where a persisted page
  number has to keep meaning what it did.
- `client.on_behalf_of = 'login'` and `client.perform_on_behalf_of` were replaced by
  `client.on_behalf_of('login')`, which returns a new client and also accepts a block. A
  blank identifier raises `ArgumentError`.
- `ZammadAPI::ResourceNotFoundError` is now `ZammadAPI::UnknownResourceError`, freeing the
  404 case to be `ZammadAPI::NotFoundError`.
- `record.save` reports a validation failure as `false` and leaves the error in
  `record.error`, instead of raising. `record.save!` is the raising form. Every other
  failure still raises from both. `client.<resource>.create` uses `save!`.
- `record.destroy` and `record.reload` raise for a record that was never saved, instead of
  acting on an id it was merely built with: `client.groups.new(id: 99).destroy` sent
  `DELETE /api/v1/groups/99`.
- `record.id = ...` raises `ZammadAPI::Error`. The id is what addresses the record, so a
  staged one made `destroy` and `save` act on another record than the one they reported on.
- `record.destroy` marks the record `destroyed?`, and `persisted?` answers false for one.
  1.x left a destroyed record looking live.
- `record.attributes` and `record.changes` are deeply frozen, and `record.to_h` returns a
  deep copy rather than a shallow one. Writing through either reader used to change what a
  record reported without staging anything, so the next `save` did not send it.
- The `record.attributes=` writer was removed. An unknown name is an ordinary attribute
  now, so `record.attributes = {name: 'Support'}` stages a change called `attributes`
  that `save` sends to Zammad. Use `assign_attributes` or `update`.
- `ZammadAPI::Error` descends from `StandardError` instead of `RuntimeError`.
- `ResponseError#response` returns a `ZammadAPI::Response`, not a Faraday object, and
  `#body` is the decoded payload rather than a raw JSON string.
- No Faraday exception escapes from a request any more: an unreachable host or a timeout
  raises `ZammadAPI::ConnectionError` or `ZammadAPI::TimeoutError`, so a
  `rescue Faraday::ConnectionFailed` stops matching.
- `ZammadAPI::ListBase`, `ListAll` and `ListSearch` were replaced by `ZammadAPI::Collection`.
- `ZammadAPI::Log` and `ZammadAPI::JsonHelper` were removed. Pass any `Logger` via `logger:`.
- `ZammadAPI::Dispatcher` was replaced by `ZammadAPI::ResourceProxy`.
- The resource readers on a client are plural: `client.tickets`, `client.users`,
  `client.groups`, `client.organizations`, `client.ticket_articles`,
  `client.ticket_priorities` and `client.ticket_states`. A resource is `Enumerable` over
  every record of its kind, so `client.ticket.each` read as if it acted on one ticket. The
  singular names raise `UnknownResourceError`, which lists the plural ones, and so does
  `client.resource(:ticket)`. `client.resource_names` lists the plural names.
- The resource readers a client has are a fixed list. 1.x resolved `client.<name>` to
  `ZammadAPI::Resources::<Name>` through `const_get`; `client.role` now raises
  `UnknownResourceError`. Hand a class of your own over instead, with
  `client.resource(Role)`.
- The internal `new_instance` accessor was replaced by `new_record?` and `persisted?`, and
  the instance-level `url` accessor by the class-level `resource_path`. Both old names now
  raise `NoMethodError`.
- A reader for an attribute the record does not carry raises `NoMethodError` instead of
  answering `nil`, so a typo no longer reads as `nil`. `record[:x]`,
  `record.fetch(:x, nil)` and `record.key?(:x)` are the readers for an attribute that may
  legitimately be absent, which it may be where Zammad serves a reduced object.
- `Collection#find` raises `ArgumentError` when given an id. On a collection it is
  `Enumerable#find`, whose argument is an ifnone callable, so `client.tickets.all.find(1)`
  answered with an `Enumerator` and made no request. Use `client.tickets.find(1)`, or
  `detect { … }` for the block form.
- `find_by` searches one string value, the longest, and compares every value against the
  hits. A lookup with no string in it, or on a resource without a search endpoint, walks
  the index instead.
- `search` raises `ZammadAPI::Error` on a resource Zammad routes no search endpoint for —
  `ticket_states`, `ticket_priorities` and `ticket_articles` — instead of reaching a 404.
- A configuration that names more than one way to authenticate raises `ConfigurationError`.
  1.x accepted a token beside a user and password and sent the first in its order without
  a word about the others. `from_env` and `with` drop the credentials an override replaces.
- `ticket.article(…)` is `ticket.add_article(…)`. A noun that sends a `POST` sat one letter
  away from `ticket.articles`, which only reads. `article` is now an attribute reader like
  any other, and the old call raises `NoMethodError`.

### Added

- `client.get`, `client.post`, `client.put` and `client.delete` reach any endpoint of the
  Zammad API, with `query:`, `body:` and `headers:`. They return a `ZammadAPI::Response`
  and keep authentication, timeouts, retries, credential redaction, JSON decoding and the
  error classes. A path is relative to the instance URL, and one that opens with a scheme
  raises `ArgumentError`, so the credentials stay with the configured instance.
- Request and connection timeouts (`timeout`, `open_timeout`), on by default at 60 and
  10 seconds. 1.x waited as long as the server took, so a call that used to hang now
  raises `TimeoutError`, or `ConnectionError` when the connection is not opened in time.
- Automatic retry with exponential backoff for a `GET` on connection failures, timeouts
  and the statuses 429, 500, 502, 503 and 504. A `Retry-After` within `timeout` is
  honoured, and a longer one ends the retries. A write is never retried: a repeated ticket
  update carrying an `article` adds that article, and sends its e-mail, twice.
- A specific error class per status: `AuthenticationError` (401), `AuthorizationError`
  (403), `NotFoundError` (404), `ValidationError` (422) and `RateLimitError` (429, with
  `#retry_after`). Network failures raise `ConnectionError` or `TimeoutError`.
- `Collection#order`, `#page`, `#in_batches`, `#find_each`, `#count`, `#pluck` and
  `#empty?`, plus `client.x.order(...)` as a shorthand for `all.order(...)`.
- `order` sorts on the server: `order(:name)`, `order(name: :desc)`,
  `order(:active, name: :desc)`, read the way ActiveRecord reads them, and a second
  `order` sorts within the first. `/api/v1/tickets` and `/api/v1/users` hardcode id order,
  so `order` on those raises `ArgumentError`; a search sorts for every resource that can be
  searched.
- `search(term, **filters)` passes its keywords on to the search endpoint, for what it
  narrows by besides the term: `condition:` and `ids:`, and `role_ids:`, `group_ids:` and
  `permissions:` on users. A blank term raises `ArgumentError`; `'*'` asks for every record.
- There is no `where`: Zammad's index endpoints sort and page and drop every other
  parameter, so filtering is `search` and `find_by`.
- A resource proxy is `Enumerable` over `all`, so `client.tickets.each`,
  `client.tickets.first(5)`, `client.tickets.map`, `#find_each`, `#in_batches`, `#page`,
  `#pluck` and `#count` all work without naming `all`. `client.x.find(id)` keeps
  its own meaning rather than becoming `Enumerable#find`; `detect` is the block form.
- `Collection#count` costs a single request on a search endpoint, which Zammad can count
  without returning the records. Elsewhere it walks.
- `Collection#first` sizes its own request: `all.first` is one request for one record and
  `all.first(5)` one request for five. `empty?` asks for one record the same way.
- A walk of an index ends at the first page shorter than the size it asked for, and a
  search walk at the first empty page, since Zammad can serve a short page with more hits
  behind it.
- `client.<resource>.find_by(**params)` and `#find_by!`, which look a record up by
  attribute value, and `client.<resource>.exists?(id)`. `find_by` answers with the first
  record that carries all the values, or `nil`: by its id where `id:` is given, through a
  search where the resource has one and a String value is given, and by walking the index
  everywhere else.
- `ResponseError` accepts a `detail:` describing a failure that has no HTTP response of its
  own, so `find_by!` reads as `no record matched`.
- The page size is clamped to what an endpoint serves (100 for `/api/v1/tickets`, 200 for
  a search, 1000 for the other index endpoints). Asking for more used to end iteration
  after the first page, because Zammad capped the response and the short page read as the
  end of the list.
- `ZammadAPI::PaginationError`, raised when an endpoint answers a page with the records of
  the page before it, instead of paging forever.
- `Base#reload`, `#persisted?`, `#destroyed?`, `#[]`, `#[]=`, `#fetch`, `#key?`, `#to_h` and
  a readable `#inspect` that blanks attributes naming a credential.
- `record.update(attributes)`, `record.update!(attributes)` and
  `record.assign_attributes(attributes)`. Attributes can be a Hash or anything with
  `to_hash`, such as permitted `ActionController::Parameters`.
- `ssl_verify`, `proxy`, `user_agent`, `retries` and `retry_interval` client options.
  The default `User-Agent` is now `zammad_api-ruby/<version>` rather than
  `Zammad API Ruby`.
- `adapter` and `middleware` client options, the seam into the Faraday stack, for a
  persistent-connection adapter or instrumentation. An adapter set inside the
  `middleware:` callable takes the place of `adapter:`. A Faraday error while building the
  connection surfaces as `ConfigurationError`.
- RBS signatures in `sig/`, verified by Steep in CI.
- `require 'zammad_api/test'` ships a stand-in Zammad for testing code that calls this
  client: `ZammadAPI::Test#stub` declares responses, `#client` hands back a real client
  wired to them, and `#requests` records what was sent, with the query as text and the
  headers by downcased name. Responses travel the same decoding, error mapping and record
  building as real ones, so a stubbed 404 raises `NotFoundError`. An unstubbed request
  raises rather than answering with something empty.
- `respond_to?` answers correctly for attribute readers and resource methods.
- Records implement `deconstruct_keys`, so they can be used with `case/in` pattern
  matching. `Config` and `Response` are `Data` objects and match as well.
- `Client#with(**options)` derives a new client with changed options. The options are
  re-validated and any `on_behalf_of` scope is carried over.
- `Client.from_env` builds a client from `ZAMMAD_URL`, `ZAMMAD_TOKEN`,
  `ZAMMAD_OAUTH2_TOKEN`, `ZAMMAD_USER` and `ZAMMAD_PASSWORD`, with
  passed-in options winning. A blank variable counts as unset.
- `Client#me`, the user the credentials authenticate as, and `Client#version`, the version
  of the Zammad instance.
- `Response#decoded(:object | :array)` checks the shape of a response body in one place,
  so an unexpected payload raises `ParseError`.
- Records compare as the Zammad records they came from: two records of the same kind with
  the same id are equal, and `#hash` agrees, so `uniq`, `Set`, `include?` and records as
  Hash keys all work. A record with no id stays equal only to itself.
- `record.to_json` and `record.as_json` render a record's attributes. `to_json` previously
  fell through to `Object#to_json`, which serialized a record as the string
  `"#<ZammadAPI::Resources::Ticket:0x...>"`.
- `client.resource(SomeClass)` takes a subclass of `ZammadAPI::Resources::Base` and answers
  with a proxy for it, so an endpoint this gem does not model gets records, pagination,
  `find_by`, change tracking and `save` from a class that declares its `path`. `searchable`,
  `max_per_page` and `sortable` say what else is true of the endpoint.
- Typed records. `ResourceProxy` and `Collection` are generic over the resource they hold,
  so `client.tickets` is a `ResourceProxy[Resources::Ticket]` and `find`, `first`,
  `find_by`, the block of `each` and a search all answer with a `Ticket`. Each resource
  declares the attributes every supported Zammad serves for it, so `ticket.title` is a
  `String` and `ticket.titel` is a type error. `spec/typed/usage.rb` is checked by
  `rake steep` the way a caller's code is.

### Fixed

- Credentials no longer reach the debug log or `inspect`: 1.x logged `user:password` when a
  client was built and wrote payloads out as they stood. Keys, query parameters and headers
  that name a credential are redacted, and a path is logged without its query string.
- An exception inside the block of `perform_on_behalf_of` no longer leaves the `From`
  header set on every later request; the block form of `on_behalf_of` scopes a client of
  its own.
- A Zammad served from a sub-path (`https://example.com/zammad/`) works; 1.x sent every
  request to the root of the host.
- Query parameters are encoded by Faraday; 1.x sent a list or a Hash, such as a search
  `condition`, as its Ruby `inspect`.
- A Hash inside an Array attribute has Symbol keys like every other; 1.x left it the
  String keys Zammad sent.
- A response body that is not JSON is no longer read as an empty Hash: a 2xx where a
  record was expected raises `ParseError`.
- An unknown resource name raises `UnknownResourceError` rather than resolving to a class
  that is not a resource, as `client.base` resolved to `Resources::Base`.
- Record ids are percent-encoded wherever they go into a path, attachment downloads and
  article lists included.
- `save` on a record with nothing staged sends no request; 1.x sent an empty `PUT`, which
  bumped `updated_at` and `updated_by`.
- `record[:x] = 1` stages the attribute it names; 1.x took it for an attribute called `[]`.
- `add_article` on a ticket that has not been saved raises `ZammadAPI::Error`, where 1.x's
  `article` posted it with `ticket_id: null`.
- A `url` carrying `user:password@` raises `ConfigurationError`, where 1.x sent those in
  place of a configured token, and so does one without a host, such as `http://:3000/`,
  which 1.x sent to localhost.
- A subclass of a resource inherits its API path; in 1.x `class MyTicket < Ticket; end`
  had none.

### Changed

- `Response#headers` is frozen, and each response carries its own.
- `client.<resource>.destroy(id)` deletes directly instead of fetching the record first.
- Resource dispatch is explicit rather than `method_missing` plus `const_get`.
- A resource declares what its endpoint does — `searchable true`, `max_per_page 100`,
  `sortable false` — the way it declares `path`.
- `client.<resource>` returns the same proxy each time rather than allocating one per call.
  The proxies are built with the client, so a client stays immutable once built and safe to
  share between threads.
- A String request body is sent as it is rather than encoded as a JSON string.
- The recursive copy behind frozen attributes, `to_h` and the test kit's recorded bodies
  lives in one place (`ZammadAPI::DeepCopy`) instead of being written once per caller.
- Unit specs (`rake spec:unit`) run without a Zammad instance; the specs that need a live
  server live in `spec/integration`, and run only where `TEST_URL` names one.
- CI runs RuboCop, Steep and the unit specs on every supported stable Ruby, and publishes
  releases through RubyGems trusted publishing.
- The integration job waits for Zammad to answer before running specs, pins the Zammad ref
  (overridable via `workflow_dispatch`), carries a timeout, uploads Zammad's logs on
  failure, and runs `script/check_connection.rb` as a preflight.
- The integration suite no longer depends on spec file order to run Zammad's auto wizard,
  and tolerates an instance that is already set up.
- `Test::UnstubbedRequestError` is a `StandardError` rather than a `ZammadAPI::Error`, so
  a forgotten stub is not caught by the `rescue ZammadAPI::Error` in the code under test.

## [1.4.0] - 2026-08-25
- Follow up - c3af2a9 - Fixes #29 - [JSON::ParserError on gateway timeout when proxy responds with HTML](https://github.com/zammad/zammad-api-client-ruby/issues/29)
- Dependencies updated

## [1.3.1] - 2026-04-28
- Fixes #29 - [JSON::ParserError on gateway timeout when proxy responds with HTML](https://github.com/zammad/zammad-api-client-ruby/issues/29)

## [1.3.0] - 2026-04-28
- Maintenance update, added minimum Ruby version 3.0.

## [1.2.0] - 2023-07-20
- Updated dependency `faraday` to `v2`.

## [1.1.0] - 2023-05-11
- Switch to dual licensing under AGPL-3.0 or MIT licenses.

## [1.0.8] - 2022-04-28
- Fixed Faraday deprecation warnings.

## [1.0.7] - 2022-04-14
- Updated package dependencies and tests.
