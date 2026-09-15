# Changelog

## [2.0.0] - 2026-08-27

A breaking release that modernises the whole gem. See
[Migrating from 1.x](README.md#migrating-from-1x) for the complete before/after guide.

### Breaking

- Minimum Ruby version is now 3.4.
- `Client.new` takes keyword arguments, so a configuration Hash has to be splatted:
  `Client.new(**config)`. A positional Hash raises `ArgumentError`.
- An unknown client option raises `ArgumentError: unknown keyword` instead of being
  ignored, so an option that is misspelled or no longer supported is no longer silent.
- `logger:` takes a `Logger` rather than a boolean flag. `logger: true` used to turn on
  debug output to `$stderr`; pass `Logger.new($stderr)` for the same thing. Any object
  that responds to `debug` is accepted, and anything else raises `ConfigurationError`.
- `Collection#each` (`client.x.all`, `client.x.search`) now walks every page. Previously it
  fetched a single page, so iterating stopped silently at 100 records for `all` and at
  10 for `search`.
- Collections are built up by chaining instead of by keyword arguments:
  `all(per_page: 50)` is now `find_each(batch_size: 50)` or `page(1, of: 50)`,
  `all(active: true)` is `search(...)` or `all.detect { ... }`,
  `search(query: 'zammad')` is `search('zammad')`,
  and `search(query: 'z', page: 2, per_page: 50)` is `search('z').page(2, of: 50)`.
  `all` accepted those keywords and then discarded them, so its page size was always
  100 and its filters never reached the request; `search` did honour `page` and
  `per_page`. All of them now raise `ArgumentError` rather than being accepted.
- `page(number, per_page)` with a block was replaced by `page(number, of: size)`, which
  returns a new collection. `page_next` and `page_prev` were removed.
- `Collection#each_page` was renamed to `#in_batches`, which also takes the page size as
  `in_batches(of: 500)`.
- `Collection#[]` was removed. It cost a request per index and ignored the page a
  collection was limited to; use `first`, or `page(n, of: 1).first` for one record at an
  offset.
- `Collection#per_page` and `#current_page` are no longer public. `inspect` reports both.
- There is no `per`. The page size belongs to the call that reads: `find_each(batch_size:)`
  to walk, `in_batches(of:)` to batch, `page(number, of:)` for one page. Everything else —
  `each`, `first`, `lazy`, `count` — fetches 100 per request.
- `where` rejects `page`, `per_page`, `expand`, `only_total_count` and `query` with an
  `ArgumentError`. They used to be accepted and silently overridden.
- A `nil` query value raises `ArgumentError`. 1.x dropped the parameter, so
  `where(owner_id: nil)` requested every ticket and the caller iterated all of them
  believing they were unassigned.
- `client.on_behalf_of = 'login'` and `client.perform_on_behalf_of` were replaced by
  `client.on_behalf_of('login')`, which returns a new client and also accepts a block.
- `ZammadAPI::ResourceNotFoundError` is now `ZammadAPI::UnknownResourceError`, freeing the
  404 case to be `ZammadAPI::NotFoundError`.
- `record.save` reports a validation failure as `false` and leaves the error in
  `record.error`, instead of raising. `record.save!` is the raising form. Every other
  failure — an expired token, a missing record, an unreachable instance — still raises from
  both, because no attribute the caller can fix would change the outcome.
  `client.<resource>.create` uses `save!`, so it keeps raising rather than returning a
  record that looks created but is not.
- `record.destroy` marks the record `destroyed?`, and `persisted?` answers false for one.
  1.x left a destroyed record looking live, so a later `save` went out as a `PUT` to the
  deleted id and came back a 404 one call after the mistake.
- `record.attributes` and `record.changes` are deeply frozen, and `record.to_h` returns a
  deep copy rather than a shallow one. Writing through either reader used to change what a
  record reported without staging anything, so the next `save` did not send it, and a
  nested hash from `to_h` was shared with the record.
- The `record.attributes=` writer was removed. An unknown name is an ordinary attribute
  now, so `record.attributes = {name: 'Support'}` stages a change called `attributes`
  that `save` sends to Zammad. Use `assign_attributes` or `update`.
- `ZammadAPI::Error` descends from `StandardError` instead of `RuntimeError`.
- `ResponseError#response` returns a `ZammadAPI::Response`, not a Faraday object, and
  `#body` is the decoded payload rather than a raw JSON string.
- No Faraday exception escapes any more: an unreachable host or a timeout raises
  `ZammadAPI::ConnectionError` or `ZammadAPI::TimeoutError`, so a
  `rescue Faraday::ConnectionFailed` stops matching.
- `ZammadAPI::ListBase`, `ListAll` and `ListSearch` were replaced by `ZammadAPI::Collection`.
- `ZammadAPI::Log` and `ZammadAPI::JsonHelper` were removed. Pass any `Logger` via `logger:`.
- `ZammadAPI::Dispatcher` was replaced by `ZammadAPI::ResourceProxy`.
- The resources a client exposes are a fixed list. 1.x resolved `client.<name>` to
  `ZammadAPI::Resources::<Name>` through `const_get`, so a subclass of `Base` defined in
  application code could be reached that way. `client.role` now raises
  `UnknownResourceError`; use the raw request methods for endpoints this gem does not
  model.
- The internal `new_instance` accessor was replaced by `new_record?` and `persisted?`, and
  the instance-level `url` accessor by the class-level `resource_path`. Both old names
  read as unknown attributes and return `nil` rather than raising, because a Zammad
  record carries administrator-defined attributes and a reader cannot tell a removed
  method from a custom field — so `if record.new_instance` silently takes the else
  branch.
- `page(number, of: size)` raises `ArgumentError` when `size` is larger than the endpoint
  serves, instead of quietly reducing it. A reduced page size moves the page:
  `page(3, of: 500)` against `/api/v1/tickets` went out as `page=3&per_page=100` and
  answered with records 201–300 rather than 1001–1500, so a job checkpointing a page
  number re-read what it had already handled. `find_each(batch_size:)` and
  `in_batches(of:)` are still reduced, because a batch size names how much to fetch per
  request, not which records the call is about.
- `find_by` builds its search term from the string values only, and raises `ArgumentError`
  when none of the values is a string. Zammad matches words, so `find_by(active: true)`
  searched for `"true"` and found nothing. Non-string values are still matched exactly, so
  `find_by(email: '…', active: true)` searches the email and compares both.
- `search` and `find_by` raise `ZammadAPI::Error` on a resource Zammad routes no search
  endpoint for — `ticket_state`, `ticket_priority` and `ticket_article`. Those endpoints
  answered 404, which reached `find_by` as a `NotFoundError` from a method documented to
  return `nil`, so `find_by(…) || create(…)` raised instead of creating. Walk those short
  lists with `all.detect { … }` instead.
- A record id of `.` or `..` raises `ArgumentError`. Both are made entirely of unreserved
  characters, so escaping carried them through and `find('..')` resolved one path level
  up — onto the index endpoint, or through a `has_many` path onto every article on the
  instance offered as one ticket's.

### Added

- `client.get`, `client.post`, `client.put` and `client.delete` reach any endpoint of the
  Zammad API, including the many this gem does not model. They return a
  `ZammadAPI::Response` and keep authentication, timeouts, retries, credential redaction,
  JSON decoding and the error classes. Previously the only way past the seven resource
  classes was to build a Faraday connection by hand.
- Request and connection timeouts (`timeout`, `open_timeout`), on by default at 60 and
  10 seconds. 1.x waited as long as the server took, so a call that used to hang now
  raises `TimeoutError`.
- Automatic retry with exponential backoff for idempotent requests on connection failures,
  timeouts and transient statuses. `POST` is never retried, so a failed create cannot
  produce duplicate records.
- A specific error class per status: `AuthenticationError` (401), `AuthorizationError`
  (403), `NotFoundError` (404), `ValidationError` (422) and `RateLimitError` (429, with
  `#retry_after`). Network failures raise `ConnectionError` or `TimeoutError` instead of
  leaking Faraday exceptions.
- `Collection#where`, `#page`, `#in_batches`, `#find_each`, `#count` and lazy
  enumeration, plus `client.x.where(...)` as a shorthand for `all.where(...)`. `where`
  accepts only parameters the endpoint reads — `sort_by` and `order_by` on a generic
  index, nothing beyond paging on `/api/v1/tickets` and `/api/v1/users`, and the search
  parameters on a `/search` endpoint — and raises `ArgumentError` for anything else.
  Zammad drops a parameter it does not know rather than refusing it, so an attribute
  filter on an index endpoint came back as the whole unfiltered list.
- A resource proxy is `Enumerable` over `all`, so `client.ticket.each`,
  `client.ticket.first(5)`, `client.ticket.map`, `#find_each`, `#in_batches`, `#page`,
  `#pluck` and `#count` all work without naming `all`. `client.x.find(id)` keeps
  its own meaning rather than becoming `Enumerable#find`; `detect` is the block form.
- `Collection#count` costs a single request on a search endpoint, which Zammad can count
  without returning the records.
- `Collection#pluck(*attributes)`, for reading one or more attributes from every record.
- `client.<resource>.find_by(**params)` and `#find_by!`, which look a record up by
  attribute value, and `client.<resource>.exists?(id)`. `find_by` searches and then
  checks the hits itself, because Zammad's index endpoints cannot filter: it returns a
  record that genuinely carries the attributes asked for, or nil. What the search can
  surface is Zammad's business, so `find_by(...) || create(...)` can still create a
  duplicate — as writing the search out by hand would. Only the first page of hits is
  examined, so a lookup costs one request whether it matches or not.
- `ResponseError` accepts a `detail:` describing a failure that has no HTTP response of its
  own, so `find_by!` reads as `no record matched` rather than `no response`. Such an error
  still reports the status its class is the name for, so a `NotFoundError` raised without a
  request answers `404` like every other one.
- The page size is clamped to what an endpoint serves (100 for `/api/v1/tickets`, 200 for
  a search, 1000 for the other index endpoints). Asking for more used to end iteration
  after the first page, because Zammad capped the response and the short page read as the
  end of the list. A walk also learns the size the endpoint actually serves from its first
  page, so an instance that pages smaller than those figures is still walked to the end
  rather than truncated.
- `find_each(batch_size:)` and `in_batches(of:)` raise when the collection is already
  limited to a page. `page(3, of: 50)` and a batch size are two ways of naming the same
  thing, and re-sizing the page behind the caller would hand back different records.
- `ZammadAPI::PaginationError`, raised when an endpoint answers a page with the page
  before it, instead of paging forever.
- `Base#reload`, `#persisted?`, `#[]`, `#fetch`, `#to_h` and a readable `#inspect`.
- `record.update(attributes)`, `record.update!(attributes)` and
  `record.assign_attributes(attributes)`. Applying a hash of changes previously meant one
  writer call per attribute before `save`.
- `ssl_verify`, `proxy`, `user_agent`, `retries` and `retry_interval` client options.
  The default `User-Agent` is now `zammad_api-ruby/<version>` rather than
  `Zammad API Ruby`.
- `adapter` and `middleware` client options, the seam into the Faraday stack. Swapping in a
  persistent-connection adapter or adding instrumentation previously meant that the HTTP
  stack was closed to callers. A Faraday error while building the connection surfaces as
  `ConfigurationError`, so Faraday stays an implementation detail.
- RBS signatures in `sig/`, verified by Steep in CI.
- `require 'zammad_api/test'` ships a stand-in Zammad for testing code that calls this
  client: `ZammadAPI::Test#stub` declares responses, `#client` hands back a real client
  wired to them, and `#requests` records what was sent. Responses travel the same decoding,
  error mapping and record building as real ones, so a stubbed 404 raises `NotFoundError`.
  An unstubbed request raises rather than answering with something empty. Consumers
  previously had to intercept HTTP to test against this client at all.
- `respond_to?` now answers correctly for attribute readers and resource methods.
- Records implement `deconstruct_keys`, so they can be used with `case/in` pattern
  matching, including against nested attributes. `Config` and `Response` are `Data`
  objects and match as well.
- `Client#with(**options)` derives a new client with changed options. The options are
  re-validated and any `on_behalf_of` scope is carried over.
- `Client.from_env` builds a client from `ZAMMAD_URL`, `ZAMMAD_TOKEN`,
  `ZAMMAD_HTTP_TOKEN`, `ZAMMAD_OAUTH2_TOKEN`, `ZAMMAD_USER` and `ZAMMAD_PASSWORD`, with
  passed-in options winning. Every example script used to repeat the same `ENV.fetch` pair.
- `Client#me`, the user the credentials authenticate as, and `Client#version`, the version
  of the Zammad instance.
- `Response#decoded(:object | :array)` validates the shape of a response body in one
  place, so an unexpected payload raises `ParseError` with a consistent message instead of
  failing further downstream.
- `record.related` reaches the records a record points at: `ticket.related.customer`,
  `ticket.related.group`, `ticket.related.articles`, `user.related.organization`, and
  `created_by` / `updated_by` on everything. Following a foreign key used to mean
  `client.user.find(ticket.customer_id)` by hand. The readers sit under `related` rather
  than on the record because Zammad expands an association into a name under the plain
  attribute, and `ticket.customer` has to keep returning that name rather than turning
  into a request. `Resource.associations` lists what a resource declares.
- Records compare as the Zammad records they came from: two records of the same kind with
  the same id are equal, and `#hash` agrees, so `uniq`, `Set`, `include?` and records as
  Hash keys all work. They previously compared by object identity, so the same ticket
  fetched twice was two unequal records. A record with no id stays equal only to itself,
  which means its first save changes its hash and a record used as a Hash key before that
  save has to be rehashed after it.
- `record.to_json` and `record.as_json` render a record's attributes. `to_json` previously
  fell through to `Object#to_json`, which serialized a record as the string
  `"#<ZammadAPI::Resources::Ticket:0x...>"`.
- `Collection#empty?`, and `#size` / `#length` as names for `#count`. `Enumerable` supplies
  none of the three, so `client.ticket.all.empty?` used to raise `NoMethodError`. `empty?`
  costs one request and asks for a single record rather than a whole page, except on a
  collection limited to one page, where the page size decides which records that page holds.
  A resource proxy forwards all three.

### Fixed

- Credentials are no longer written to the debug log. The old transport logged
  `user:password` on every client build; payload keys such as `password` and `token` are
  now redacted, and `Config#inspect` redacts credentials.
- `on_behalf_of` no longer leaks: the old `perform_on_behalf_of` used `tap` without an
  `ensure`, so an exception inside the block left the `From` header set on every later
  request.
- Zammad installations served from a sub-path (`https://example.com/zammad/`) now work.
  Request paths are relative, so the prefix is no longer stripped.
- Query parameters are encoded by the HTTP layer, including arrays and characters that
  need escaping.
- Nested attributes inside arrays are symbolized consistently.
- A malformed or non-JSON response body no longer degrades into an empty hash that
  callers then iterate as key/value pairs.
- Unknown resource names no longer resolve to unrelated Ruby classes.
- Record ids are escaped everywhere they reach a path, including the attachment download
  endpoint and `has_many` association paths, so an id carrying a traversal cannot redirect
  a request onto another endpoint.
- A credential carrying an unencoded `@` is redacted whole. Redaction stopped at the first
  `@`, so the tail of such a password survived into `Config#inspect` and into every
  `ConnectionError` message.
- `Transport#with_config` keeps the transport's own class, so a stand-in written as a
  `Transport` subclass survives `client.with(...)` instead of reverting to a real HTTP one.
- `save` on a persisted record with nothing staged sends no request. The empty `PUT` it
  used to issue was applied by Zammad, bumping `updated_at` and `updated_by`.
- A nested query parameter is sent as a structure rather than as its Ruby `inspect`.
  `condition`, which the search endpoints narrow by and which `where` accepts, went out as
  `condition=%7B%22ticket.state_id%22…`; Zammad could not parse it, dropped it, and
  answered with an unnarrowed search. A `nil` is now refused at any depth, and the message
  names the path to it.
- Bare socket failures are retried. `Errno::ECONNRESET` and the rest were mapped to
  `ConnectionError` but were missing from the retriable list, so a transient failure
  through an adapter that wraps it (net_http) was retried while the same failure through
  an adapter that does not raised on the first attempt.
- `where` reads a String key as the parameter it names. Both guards compared against
  Symbols, so `where('sort_by' => 'name')` was refused with a message saying the endpoint
  both ignores and honours `sort_by`, and `where('page' => 2)` slipped past the
  reserved-key check entirely.
- A list body that is not made of objects raises `ParseError` instead of failing later. An
  unexpanded search answering `[1, 2, 3]` stored an Integer as a record's attributes, and
  the first reader died with `TypeError: no implicit conversion of Symbol into Integer`.
- `destroy` clears the staged changes, the last validation error and the association
  readers. A destroyed record went on reporting `changed?` and a change set that can never
  be sent, and `record.related` went on requesting a record that no longer exists.
- `Config#redacted_url` no longer mangles a URL whose query string contains an `@`.
  `https://host?a=b@c` was rendered as `https://[REDACTED]@c`, a host that does not exist,
  in every `ConnectionError` and `TimeoutError` message.
- The RBS signatures the gem ships validate on their own. They named Faraday types that
  are declared only in `sig/vendor`, which is deliberately not published, so `rbs validate`
  failed for every consumer with `Could not find Faraday::Connection`.
- `ZammadAPI::Test.new` no longer builds a Faraday stack it immediately discards, which a
  suite using `let(:zammad) { ZammadAPI::Test.new }` paid for once per example.
- The trailing slash a base URL is normalised with lands on the path rather than at the end
  of the string. `https://host/zammad?tenant=acme` became `https://host/zammad?tenant=acme/`,
  which every request was then resolved against and every `ConnectionError` printed.
- `Config` refuses a URL with a scheme and no host, and one that is not a String. Both used
  to be accepted: `'https://'` failed deep inside the adapter on the first request, and a
  `URI` — what `URI(...)` hands back, and it prints as the URL — died as a `NoMethodError`
  past the `ConfigurationError` the constructor is documented to raise.
- `user_agent: nil` falls back to the gem's own value instead of reaching Faraday as a nil
  header, which Faraday filled in with its own — so the gem silently stopped identifying
  itself in the instance log an operator greps to find its requests. A `user_agent` that is
  not a String raises `ConfigurationError`.
- Proxy credentials are redacted whether or not the proxy URL carries a scheme.
  `proxy: 'user:secret@proxy:8080'` — the shape an `http_proxy` setting is copied out of —
  rendered in `Config#inspect` in full.
- A `proxy` that is not a URL, and a `middleware` callable that raises, are reported as
  `ConfigurationError`. Only `Faraday::Error` was wrapped, so these escaped as
  `URI::InvalidURIError` and as whatever the callable raised, past the
  `rescue ZammadAPI::ConfigurationError` around building a client.
- The debug log redacts `api_key`, `apikey`, `passwd`, `pwd` and a bare `key` as well. The
  pattern matched `private_key` but not the other key spellings, and `password` but not its
  short forms, so those payload values were written out in full.
- `destroyed?` is sticky. `reload` re-read a record that no longer exists and cleared the
  flag on the way back, so a destroyed record came back reporting itself as `persisted?`
  and its next `save` issued a `PUT` against the deleted path; a second `destroy` surfaced
  Zammad's 404 rather than saying the record was already gone. `save`, `reload` and
  `destroy` now all refuse a destroyed record with the same local error.
- `record.fetch` refuses more than one fallback, the way `Hash#fetch` does. `fetch(:a, :b,
  :c)` — a multi-key read this has never been — was answered with `:b`.
- `find_by` quotes a value that would otherwise be read as search syntax.
  `find_by(note: 'a AND b')` went out as a boolean query, and a value carrying an
  unbalanced bracket or quote went out as a query Zammad's parser rejects, so a method
  documented to answer a miss with `nil` answered it with a 4xx.
- A collection smaller than one page costs one request rather than two. The walk confirms
  the end of a short page with another request, which could only ever come back empty; it
  now stops on the total the endpoint reports alongside the page, and only falls back to
  confirming when the endpoint reports none. The total has to be corroborated by the page
  it arrived with — the page came back short of the size requested, and exactly as many
  records were seen as the total names. It is the one stop condition not derived from the
  records the endpoint served, and a total that under-reports (a count taken before
  permission scoping, a stale cache, a proxy rewriting the header) ended the walk early:
  100 of 150 records came back, nothing was raised, and nothing told that result apart
  from a complete one.
- The test kit records a request body by value. Held by reference, a test that built one
  payload, sent it, then changed it for a second call rewrote the first recorded request
  and asserted against a body that never went anywhere. `Test#inspect` also reads the
  recorded requests under the monitor that guards them.
- A record is persisted because Zammad answered 2xx, not because the answer parsed. The
  create response was decoded before the flag went down, so a 201 carrying something other
  than a JSON object — an HTML error page from an intervening proxy — raised `ParseError`
  with the record still looking new. The ticket existed in Zammad while the record here did
  not, and a retried `save` POSTed a second one.
- A `ConfigurationError` raised while building the connection no longer quotes the proxy
  credentials. `proxy: 'http://user:pa ss@host:3128'` came back as
  `URI::InvalidURIError` with the whole URL, password included, in a message that lands in
  every log and exception report — the case `Config#inspect` exists to prevent, reached by
  another route.
- `Config` refuses a `proxy` that is not a String, an `adapter` that cannot be a Symbol,
  and an `ssl_verify` that is not a boolean. A `URI` proxy was accepted and then died as a
  `NoMethodError` inside `inspect`, so the object documented as safe to log raised at the
  moment something logged it; `adapter: 1` and `adapter: true` escaped the constructor as
  `NoMethodError`; and `ssl_verify: 'false'` — a plausible environment read — is the
  truthy string `"false"`, so verification stayed on while the caller believed otherwise.
- An `OpenSSL::SSL::SSLError` that an adapter did not wrap is mapped to `ConnectionError`
  like its Faraday counterpart. Unlisted, a certificate mismatch through such an adapter —
  and this gem lets a caller choose one — escaped `request` raw, past every
  `rescue ZammadAPI::Error`. It is not retried: a rejected certificate is a fact about the
  instance, not a transient failure.
- A resource subclassed by a caller keeps its parent's API path. Class-level state is not
  inherited, so `class MyTicket < Ticket; end` inherited all nine of Ticket's associations,
  its page limit and its searchability, and lost only the path — `MyTicket.resource_path`
  raised "does not declare an API path" from a class that plainly did.
- The test kit answers a later page of a singly-stubbed list endpoint the way an endpoint
  out of records would. A stub that kept serving the same records to every page tripped the
  repeated-page guard, so the obvious `stub(:get, 'api/v1/groups', body: [...])` made every
  full read of that collection raise `PaginationError`. Against a real Zammad the same code
  works, because page 2 comes back empty; the stand-in was what differed. A stub that names
  a `page` is still served exactly as written.
- The test kit sequences stubs within an identical query scope rather than across every
  scoped stub for an endpoint. Two stubs naming different parameters both match a request
  carrying all of them, and they were read as a sequence: stubbing a search once for its
  records and once for its count made `count` consume the records stub, hand back an Array
  where a count belonged, and then report the endpoint as unstubbed. The most specific
  scope now answers, and two that are equally specific raise
  `ZammadAPI::Test::AmbiguousStubError` rather than one of them being picked.
- `Collection#count` reads the total from the header when a search endpoint ignores
  `only_total_count`. The probe came back as the usual page of records and was thrown away,
  so the answer cost 1 + N requests instead of N.

### Changed

- `client.<resource>.destroy(id)` deletes directly instead of fetching the record first.
- Resource dispatch is explicit rather than `method_missing` plus `const_get`.
- A resource declares what its endpoint does — `searchable true`, `max_per_page 100`,
  `index_query_keys :sort_by` — the way it already declared `path`, rather than by setting
  `SEARCHABLE`, `MAX_PER_PAGE` and `INDEX_QUERY_KEYS`. A misspelled constant was silently
  ignored and the resource kept Base's default, so `SEARCHEABLE = true` left the resource
  unsearchable and every `find_by` on it raised "Zammad routes no search endpoint" with no
  hint that the declaration was the problem; a misspelled declaration is a `NoMethodError`
  at load.
- `client.<resource>` returns the same proxy each time rather than allocating one per call.
  Clients from `#with` and `#on_behalf_of` start with proxies of their own, so none is
  shared with the transport it was derived from.
- The recursive copy behind frozen attributes, `to_h` and the test kit's recorded bodies
  lives in one place (`ZammadAPI::DeepCopy`) instead of being written once per caller.
- Unit specs (`rake spec:unit`) run without a Zammad instance; the specs that need a live
  server live in `spec/integration`.
- CI runs RuboCop, Steep and the unit specs on every supported stable Ruby, and publishes
  releases through RubyGems trusted publishing.
- The integration job now waits for Zammad to answer before running specs, promotes
  Zammad's generated CI environment into the job so it survives across steps, pins the
  Zammad ref (overridable via `workflow_dispatch`), carries a timeout, and uploads Zammad's
  logs on failure. It also runs `script/check_connection.rb` as a preflight, so a broken
  gem-to-Zammad link fails in seconds with a readable transcript instead of 53 spec errors.
- The integration suite no longer depends on spec file order to run Zammad's auto wizard,
  and tolerates an instance that is already set up. Its lifecycle examples are pinned to
  definition order and say what is missing when only part of a file is run.
- `Test::UnstubbedRequestError` is a `StandardError` rather than a `ZammadAPI::Error`, so
  a forgotten stub is not caught by the `rescue ZammadAPI::Error` in the code under test.
- The test kit matches array-valued query stubs, such as `query: {ids: [1, 2]}`, which
  could never match before.

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
