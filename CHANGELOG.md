# Changelog

## [2.0.0.alpha1] - 2026-11-17

The first prerelease of 2.0, a breaking release that modernises the whole gem. See
[Migrating from 1.x](README.md#migrating-from-1x) for the complete before/after guide.

Everything below is what changed since 1.4.0. It is published as an alpha so that it can
still change: names, defaults and behaviour may differ in 2.0.0. A prerelease has to be
asked for, with `gem install zammad_api --pre` or `gem 'zammad_api', '~> 2.0.0.alpha'`.

### Breaking

- Minimum Ruby version is now 3.4. 3.0 through 3.2 are end-of-life, and 3.3 is in security
  maintenance until March 2027. The library needs nothing from 3.4 but the `it` block
  parameter, so the floor is a choice rather than a dependency.
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
  `all(per_page: 50)` is now `find_each(batch_size: 50)` or `page(1, per_page: 50)`,
  `all(active: true)` is `search(...)` or `all.detect { ... }`,
  `search(query: 'zammad')` is `search('zammad')`,
  and `search(query: 'z', page: 2, per_page: 50)` is `search('z').page(2, per_page: 50)`.
  `all` accepted those keywords and then discarded them, so its page size was always
  100 and its filters never reached the request; `search` did honour `page` and
  `per_page`. All of them now raise `ArgumentError` rather than being accepted.
- `page(number, per_page)` with a block was replaced by `page(number, per_page: size)`, which
  returns a new collection. `page_next` and `page_prev` were removed.
- `Collection#each_page` was renamed to `#in_batches`, which also takes the page size as
  `in_batches(of: 500)`.
- `Collection#[]` was removed. It cost a request per index and ignored the page a
  collection was limited to; use `first`, or `page(n, per_page: 1).first` for one record at an
  offset.
- `Collection#per_page` and `#current_page` are no longer public. `inspect` reports both.
- There is no `per`. The page size belongs to the call that reads: `find_each(batch_size:)`
  to walk, `in_batches(of:)` to batch, `page(number, per_page:)` for one page. Everything else
  fetches as many records as the endpoint serves.
- A collection fetches the endpoint's own page size rather than a fixed 100 — 1000 on the
  index endpoints, 100 on `/api/v1/tickets`, 200 on a search — so a walk spends roughly a
  tenth of the round trips, each of which is a fresh TLS handshake under Faraday's default
  adapter. `page(n)` without `per_page:` is a page of that size, so pin it with
  `page(n, per_page: 100)` where a persisted page number has to keep meaning what it did.
- A `nil` query value raises `ArgumentError`. 1.x dropped the parameter, so a filter that
  happened to be `nil` requested every record and the caller iterated all of them
  believing they had been narrowed.
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
- A resource's class-level memos — the association proxy class and the `belongs_to`
  foreign keys — are built under a lock. They were plain `@x ||=`, so two threads building
  clients or reading associations at once could each build a different anonymous proxy
  class for one resource, and whichever write lost was still held by the records already
  built from it. Harmless under CRuby's GVL, wrong on JRuby and TruffleRuby, which is not
  the contract `README` writes down.
- `record[:x] = 1` stages the attribute it names. It reached the writer dispatch as `[]=`
  and was taken for an attribute literally called `[]` whose value was the index, so the
  write was lost without an error and the next `save` sent `{"[]": "x"}` to Zammad. Ruby's
  operators end in `=` too, so `record <= 5` invented an attribute called `<` the same way;
  a writer is now recognised only by a plain attribute name.
- `record.destroy` and `record.reload` refuse a record that was never saved, instead of
  acting on an id it was merely built with. `client.groups.new(id: 99).destroy` reported
  `new_record?` true and `persisted?` false and still sent `DELETE /api/v1/groups/99`.
- `record.id = ...` raises. The id is what addresses the record, so a staged one took
  effect for every path that builds a URL from the attributes and not at all for the record
  those paths then reported on: `group.id = 99; group.destroy` sent `DELETE` to group 99
  and left the record saying group 1 was the one destroyed. Zammad does not let an id be
  set either, so no call that used to reach the server is lost. The constructor refuses it
  too: `client.groups.new(id: 5)` raises, because a new record is sent in full, so the one
  spelling that reached the wire was the one nothing checked. `Resource.from_response` is
  how a body Zammad served becomes a record carrying its id.
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
- The resource readers on a client are plural: `client.tickets`, `client.users`,
  `client.groups`, `client.organizations`, `client.ticket_articles`,
  `client.ticket_priorities` and `client.ticket_states`. A resource is `Enumerable` over
  every record of its kind, so `client.ticket.each` and `client.ticket.first(5)` read as if
  they acted on one ticket; the singular dates from 1.x, when a resource was only a
  dispatcher for `find` and `create`. The singular names still work, as deprecated aliases
  that warn in Ruby's `deprecated` category — silent unless the application asks for
  deprecation warnings, with `ruby -W:deprecated` or `Warning[:deprecated] = true` — and
  will be removed in 3.0. `client.resource(:ticket)` is answered the same way, and
  `client.resource_names` lists the plural names.
- The resource readers a client has are a fixed list. 1.x resolved `client.<name>` to
  `ZammadAPI::Resources::<Name>` through `const_get`, so a subclass of `Base` defined in
  application code could be reached that way. `client.role` now raises
  `UnknownResourceError`; hand the class over instead, with `client.resource(Role)`.
- The internal `new_instance` accessor was replaced by `new_record?` and `persisted?`, and
  the instance-level `url` accessor by the class-level `resource_path`. Both old names now
  raise `NoMethodError` as unknown attributes, naming the attributes the record does carry.
- A reader for an attribute the record does not carry raises `NoMethodError` instead of
  answering `nil`. A typo read as `nil` and flowed on into whatever was written with it,
  and `respond_to?` and `method` disagreed with the call throughout, so generic code that
  asks before it calls was told the reader did not exist. `record[:x]`,
  `record.fetch(:x, nil)` and `record.key?(:x)` are the readers for an attribute that may
  legitimately be absent — which it may, because Zammad serves a reduced object where the
  authenticated user may not see the whole record, and the message says so.
- `Collection#find` raises `ArgumentError` when given an id. `find` on a resource proxy is
  the lookup by id; on a collection it is `Enumerable#find`, whose argument is an ifnone
  callable — so `client.tickets.all.find(1)` answered with an `Enumerator`, made no request
  and raised nothing. Use `client.tickets.find(1)`, or `detect { … }` for the block form.
- `TicketArticle#attachments` raises `ParseError` for attachment metadata that is not a
  list of objects, where it used to die with a bare `NoMethodError` from inside the gem —
  past the `rescue ZammadAPI::Error` every caller is told to write.
- `page(number, per_page: size)` raises `ArgumentError` when `size` is larger than the endpoint
  serves, instead of quietly reducing it. A reduced page size moves the page:
  `page(3, per_page: 500)` against `/api/v1/tickets` went out as `page=3&per_page=100` and
  answered with records 201–300 rather than 1001–1500, so a job checkpointing a page
  number re-read what it had already handled. `find_each(batch_size:)` and
  `in_batches(of:)` are still reduced, because a batch size names how much to fetch per
  request, not which records the call is about.
- `find_by` searches one string value — the longest. Zammad matches words, so
  `find_by(active: true)` searched for `"true"` and found nothing. Every other value is
  compared against the record, so `find_by(email: '…', active: true)` searches the email
  and compares both, and a lookup with no string in it walks the index instead. The values are
  never joined into a single term: an instance searching without Elasticsearch matches the
  term literally, through a SQL `LIKE` over each string column, so
  `find_by(firstname: 'Jane', lastname: 'Doe')` asked for one column containing
  `"Jane Doe"` and reported a user that exists as `nil`.
- `search` raises `ZammadAPI::Error` on a resource Zammad routes no search endpoint for —
  `ticket_states`, `ticket_priorities` and `ticket_articles`. Those endpoints answered 404,
  which arrived as a `NotFoundError` about a record from a call that asked for a list, and
  reached `find_by` the same way, so `find_by(…) || create(…)` raised instead of creating.
  `find_by` walks those lists instead of searching them.
- Nothing reads an `x-total-count` response header any more, because Zammad has never sent
  one — from any endpoint, in any version. `Response#reported_total` was built on it, and
  two guards read that: `Collection#each` would have ended a walk one request early on the
  reported figure, and a `has_many` reader would have refused a list it judged truncated.
  Both were dead, and the one that could have acted was the one that could have been
  wrong, since it ends a walk on a figure the records do not corroborate. Zammad reports a
  total in the body instead, and only where asked: `only_total_count` — which is what
  `Collection#count` uses on a search — or `with_total_count` on `/search`, and `full` on
  the index endpoints that render through `model_index_render`.
- A record id of `.` or `..` raises `ArgumentError`. Both are made entirely of unreserved
  characters, so escaping carried them through and `find('..')` resolved one path level
  up — onto the index endpoint, or through a `has_many` path onto every article on the
  instance offered as one ticket's.
- A configuration that names more than one way to authenticate raises `ConfigurationError`.
  `http_token`, `oauth2_token` and `user` with `password` used to be accepted together, and
  the first of them in that order was sent without a word about the others — which is what
  let `from_env(user:, password:)` and `with(oauth2_token:)` keep sending an old token. A
  client authenticates one way by construction now. `from_env` and `with` drop the
  credentials an override replaces, so switching schemes through either still works, and an
  environment that itself sets two schemes is refused until an argument says which is meant.
- `ticket.article(…)` is `ticket.add_article(…)`. A noun that sends a `POST` sat one letter
  away from `ticket.articles`, which only reads. `article` still works, as a deprecated
  alias that warns in Ruby's `deprecated` category the way the singular resource readers do,
  and will be removed in 3.0.

### Added

- `Collection#first` and `#take` size their own request: `all.first` is one request for one
  record and `all.first(5)` one request for five, where `Enumerable` took them off the
  front of a page sized for walking. The request is sized rather than the collection
  limited to a page, so a read still walks on where a page comes back shorter than it was
  asked for — `first(5)` answers with five records if five exist. A collection `page`
  already limited keeps its own size, because that size says which records it holds.
- `client.get`, `#post`, `#put` and `#delete` take `headers:`, for an endpoint that needs
  one. Names are case-insensitive and two spellings of one header are refused rather than
  merged; `Authorization` and `From` are refused outright, being what the client's
  credentials and `on_behalf_of` are for.
- `Test::Request#headers` records the headers a request asked for, stringified and
  downcased through the real transport's own rules, so a stand-in cannot accept a header
  the wire would refuse.
- `client.get`, `client.post`, `client.put` and `client.delete` reach any endpoint of the
  Zammad API, including the many this gem does not model. They return a
  `ZammadAPI::Response` and keep authentication, timeouts, retries, credential redaction,
  JSON decoding and the error classes. Previously the only way past the seven resource
  classes was to build a Faraday connection by hand.
- Request and connection timeouts (`timeout`, `open_timeout`), on by default at 60 and
  10 seconds. 1.x waited as long as the server took, so a call that used to hang now
  raises `TimeoutError`.
- Automatic retry with exponential backoff for a `GET` on connection failures, timeouts
  and transient statuses. A write is never retried. `POST` would create a second record,
  and `PUT` and `DELETE` are not safe to repeat against Zammad either: a ticket update
  carrying an `article` adds that article, and sends its e-mail, once per delivery, and a
  `DELETE` repeated after a lost answer comes back as a 404 for a record that was just
  deleted, so `destroy` raised `NotFoundError` and left the record looking live.
- A specific error class per status: `AuthenticationError` (401), `AuthorizationError`
  (403), `NotFoundError` (404), `ValidationError` (422) and `RateLimitError` (429, with
  `#retry_after`). Network failures raise `ConnectionError` or `TimeoutError` instead of
  leaking Faraday exceptions.
- `Collection#order`, `#page`, `#in_batches`, `#find_each`, `#count` and lazy
  enumeration, plus `client.x.order(...)` as a shorthand for `all.order(...)`.
- `order` sorts on the server: `order(:name)`, `order(name: :desc)`,
  `order(:active, name: :desc)`, read the way ActiveRecord reads them, and a second
  `order` sorts within the first. Sorting is the one thing an index endpoint does besides
  paging. `/api/v1/tickets` and `/api/v1/users` do not even do that — their controllers
  hardcode id order — so `order` on those raises `ArgumentError` rather than handing back
  records it would be calling sorted; a search sorts for every resource that can be
  searched.
- `search` takes what a search endpoint narrows by besides the term as keywords:
  `condition:` and `ids:` on every search, and `role_ids:`, `group_ids:` and `permissions:`
  on users, the one search that reads them. Any other keyword raises `ArgumentError`,
  because Zammad drops a parameter it does not know rather than refusing it, and the search
  would come back unnarrowed with nothing to say so. That includes a user keyword on
  another resource: `tickets.search('printer', group_ids: [2])` was sent as written and
  answered with tickets from every group, where a `condition` on `ticket.group_id` is what
  narrows them. A resource of your own declares what its search reads with
  `search_filters`. `group_ids:` is a list of group ids, for the agents with `full` access
  to them, or a Hash of group id to access, `group_ids: {2 => ['read']}`, for any other:
  Zammad reads a group named without an access as `full`. `permissions:` is not an access
  check: where Zammad searches through Elasticsearch, a permission no active role grants
  leaves the search unnarrowed, and the README says what to use instead.
- There is no `where`. During the development of 2.0 there was one, which took `sort_by`
  and `order_by` on a generic index, nothing at all on tickets and users, and the search
  parameters on a search, and raised for everything else — an attribute filter above all,
  since Zammad's index endpoints do not filter. The most familiar verb on a collection
  refused nearly everything it was given, so the two things it did do have names of their
  own: `order`, and the keywords of `search`.
- A resource proxy is `Enumerable` over `all`, so `client.tickets.each`,
  `client.tickets.first(5)`, `client.tickets.map`, `#find_each`, `#in_batches`, `#page`,
  `#pluck` and `#count` all work without naming `all`. `client.x.find(id)` keeps
  its own meaning rather than becoming `Enumerable#find`; `detect` is the block form.
- `Collection#count` costs a single request on a search endpoint, which Zammad can count
  without returning the records.
- `Collection#pluck(*attributes)`, for reading one or more attributes from every record.
- `client.<resource>.find_by(**params)` and `#find_by!`, which look a record up by
  attribute value, and `client.<resource>.exists?(id)`. `find_by` answers on every
  resource and for any kind of value: the first record that carries the values, `nil` if
  it finds none. It fetches candidates and checks them itself, because Zammad's index
  endpoints cannot filter — through a search where the resource has a search endpoint and
  one of the values is a string, and by walking the index everywhere else, which is what
  `ticket_states`, `ticket_priorities` and `ticket_articles` and a lookup such as
  `find_by(active: true)` get. A walk costs a request per page until a record matches. It
  returns a record that genuinely carries the attributes asked for, or nil; a record that
  does not carry an attribute does not match it, not even for `nil`. What the search can
  surface is Zammad's business, so `find_by(...) || create(...)` can still create a
  duplicate — as writing the search out by hand would. Without Elasticsearch a search
  reads only the string columns of a user, organization or group, and of a ticket only the
  title, the number and its articles, so a lookup by anything else answers `nil` there;
  the README lists what that covers and why `find_by` does not walk the index after a
  miss. Every page of hits is read until
  one matches, so a miss costs a request per page of hits: Zammad's search sorts by
  `updated_at`, newest first, rather than by relevance, so the exact match can be on any
  page.
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
  limited to a page. `page(3, per_page: 50)` and a batch size are two ways of naming the same
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
  `client.users.find(ticket.customer_id)` by hand. The readers sit under `related` rather
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
  none of the three, so `client.tickets.all.empty?` used to raise `NoMethodError`. `empty?`
  costs one request and asks for a single record rather than a whole page, except on a
  collection limited to one page, where the page size decides which records that page holds.
  A resource proxy forwards all three.
- `client.resource(SomeClass)` takes a subclass of `ZammadAPI::Resources::Base` and answers
  with a proxy for it, so an endpoint this gem does not model gets records, pagination,
  `find_by`, change tracking and `save` from a class that declares its `path`: `class Role <
  ZammadAPI::Resources::Base; path 'api/v1/roles'; end`, then `client.resource(Role).each {
  … }`. `Base` already supported being subclassed, and `searchable`, `max_per_page`,
  `sortable`, `belongs_to` and `has_many` are there to say what else is true of the
  endpoint; what was missing since `const_get` went was a public way to a proxy for one,
  which left raw requests as the only way to the rest of the API. An association on such a
  class can point at another by its full name, `class_name: 'Acme::Role'`.
- Typed records. `ResourceProxy` and `Collection` are generic over the resource they hold,
  so `client.tickets` is a `ResourceProxy[Resources::Ticket]` and `find`, `first`,
  `find_by`, the block of `each` and a search all answer with a `Ticket` where the
  signatures said `untyped`. Each resource declares the attributes every supported Zammad
  serves for it — the columns of its table, typed the way their JSON arrives — so
  `ticket.title` is a `String` and `ticket.titel` is a type error. Attributes an
  administrator added are read with `record[:name]` or declared by reopening the class in a
  project's own signatures; the README's Type signatures section says what else is left
  undeclared and why. `spec/typed/usage.rb` is checked by `rake steep` the way a caller's
  code is, and pins these types from the outside.

### Fixed

- Credentials are no longer written to the debug log. The old transport logged
  `user:password` on every client build; payload keys such as `password` and `token` are
  now redacted, and `Config#inspect` redacts credentials. A `ConfigurationError` raised
  while building the connection redacts the configured url and proxy out of the underlying
  message too, including where that message quoted the value through `inspect` rather than
  interpolating it — which is what `URI::InvalidURIError` does, for exactly the characters
  that make a URL invalid.
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
  `condition`, which the search endpoints narrow by and which `search` takes, went out as
  `condition=%7B%22ticket.state_id%22…`; Zammad could not parse it, dropped it, and
  answered with an unnarrowed search. A `nil` is now refused at any depth, and the message
  names the path to it.
- Bare socket failures are retried. `Errno::ECONNRESET` and the rest were mapped to
  `ConnectionError` but were missing from the retriable list, so a transient failure
  through an adapter that wraps it (net_http) was retried while the same failure through
  an adapter that does not raised on the first attempt.
- A list body that is not made of objects raises `ParseError` instead of failing later. An
  unexpanded search answering `[1, 2, 3]` stored an Integer as a record's attributes, and
  the first reader died with `TypeError: no implicit conversion of Symbol into Integer`.
  A `null` among the records is refused as well. It passed the check, which could not tell
  a `nil` it had found from having found nothing, and a walk then raised `NoMethodError`
  reading the ids of the page.
- `destroy` clears the staged changes and the last validation error, and refuses the
  association readers. A destroyed record went on reporting `changed?` and a change set
  that can never be sent, and `record.related` went on requesting a record that no longer
  exists — dropping the memo was not enough on its own, because the reader rebuilt one on
  the next call. `record.related`, `ticket.articles` and `ticket.add_article(…)` all raise
  `ZammadAPI::Error` for a destroyed record now, rather than reaching the server for it.
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
  not, and a retried `save` POSTed a second one. What that leaves behind is a record that
  is persisted and has no id, and `save`, `reload` and `destroy` all refuse it by name
  rather than pretending: a record built by `new` has nothing staged, so the retried `save`
  took the "nothing changed, nothing to send" short circuit and returned `true` without
  making a single request, for a record that may or may not be in Zammad.
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
- `update` and `update!` refuse a destroyed record before staging anything. They assigned
  first and saved second, and `save!` is where the destroyed check lives, so `update` on a
  destroyed record raised and left it `changed?` with a change set that can never be
  sent — the state `destroy` clears the staged changes to prevent.
- Writing an attribute the record does not carry is a change, and is sent. Zammad reduces
  the object it serializes for a permission-scoped client, so a key being absent says
  nothing about what is stored; read as a `nil` original, `group.note = nil` compared equal
  to nil, staged nothing and was still merged into the attributes. The write was dropped
  without a word, `save` returned `true` having sent no request, and the record went on
  reporting a key Zammad never sent it, so `changes` and `attributes` disagreed.
- `ticket.add_article(...)` refuses a ticket that has not been saved instead of POSTing
  `ticket_id: null` and leaving the caller to read Zammad's 422 for the reason. Every other
  path in the gem that needs a stored id says so locally.
- The documentation no longer promises that a `has_many` reader refuses a partial list
  with `ZammadAPI::PaginationError`. The check behind that promise read a total from an
  `x-total-count` response header, which Zammad has never sent, so it never ran and was
  removed — see the entry on that header under Breaking — while this entry, the README and
  the comment on `has_many` went on describing it. A `has_many` list is read in a single
  request because the association endpoints Zammad routes serve the whole thing:
  `ticket_articles/by_ticket` renders every article of the ticket and reads no paging
  parameter. Nothing in a response tells a whole list from the first page of one, so
  there is no honest check to put in its place.
- The documented page sizes are sizes the endpoints actually serve. Every `find_each` and
  `in_batches` example used `of: 500` against `client.tickets`, which caps at 100, so each
  headline example did something other than what it showed. The clamp itself stands — a
  batch size says how much to fetch at a time, not which records you get, which is why
  `page` refuses an oversize size and a walk reduces it.
- A destroyed record reports the attributes Zammad last served, not a write that never
  left the process. `destroy` dropped the staged change set and left the writes it
  described standing, so `group.name = 'B'; group.destroy` answered `changed?` with false,
  `changes` with `{}` and `name` with `"B"` — with nothing left to tell a local edit apart
  from a value the server gave, in the one state where it can never be saved.
- A record Zammad served without an id is no longer told it "was saved". Zammad serves a
  reduced object where the authenticated user may not see the whole record, so a plain read
  can hand back a persisted record with no id; the message sent the caller to look at a
  save that never happened instead of at what the client may read.
- `require 'zammad_api'` no longer depends on Faraday loading `net/http` for it.
  `Timeout::Error` and `SocketError` are named in `Transport`'s class body and resolved
  only because the default adapter pulled `timeout` and `socket` in transitively — so a
  Faraday that stopped doing that, or a slimmer adapter, turned the require into a
  `NameError` before a single request.
- `middleware:` that decodes the response body — `c.response :json` is the usual one — is
  refused when the client is built, before anything is sent, with a `ConfigurationError`
  naming it. Faraday's parsed Hash used to become a Ruby inspect string that `JSON.parse`
  refused, which killed every record built from it with a `ParseError` naming Zammad for
  what the caller's stack had done. This gem parses JSON itself and hands the undecoded
  bytes to attachment downloads, so once a middleware has consumed the body there is
  nothing faithful left to hand back.
- Two spellings of one query parameter raise instead of silently sending whichever Hash
  order put last — at any depth, and in `search` at the call that wrote it as well as on
  the wire. The same goes for two spellings of one response header in `ZammadAPI::Test`. Keys are normalised
  in both places, so `search('x', 'ids' => [1], ids: [2])` and
  `{state_id: 1, 'state_id' => 2}` each collapsed into one parameter and dropped the other
  value without a word — including inside `condition`, the structured parameter the search
  endpoints read.
- A stubbed response from `ZammadAPI::Test` carries `content-type` the way a real one does,
  and is decoded by that header rather than by the Ruby type of the stub's body. Code that
  branches on `response.headers['content-type']` passed against Zammad and failed against
  the stand-in, or the reverse; and a stub declaring a non-JSON type still handed back a
  decoded Hash, where Zammad gives the raw string and reading a record from it raises
  `ParseError`.
- `record.fetch(:missing, default) { ... }` warns the way `Hash#fetch` warns, naming the
  line that made the call. A bare `Kernel#warn` reports no source location, so the warning
  identified neither the call site nor the library it came from.
- A raw request refuses an absolute URL with `ArgumentError`. Faraday lets one replace the
  instance URL and still attaches the client's headers, so
  `client.get('https://other.example/collect')` — a link taken from a response body, say —
  sent the access token and the `on_behalf_of` scope to that host. The path is documented as
  relative to the instance URL, and record ids were already held inside their segment; this
  is the same escape one level up. The test kit refuses it too.
- An instance `url` that carries credentials raises `ConfigurationError`. Faraday turns the
  userinfo of a URL into a Basic `Authorization` header, and its authorization middleware
  leaves a header that is already set alone, so with `url: 'https://old:pass@host/'` and
  `http_token: 'new'` every request went out as the old account while `client.inspect`
  reported `auth=http_token` — the token was never sent. Credentials belong in `user:` and
  `password:`, or in one of the token options.
- `Client.from_env(**overrides)` and `Client#with` replace the credentials they override. A
  credential is one of several options read in a fixed order, so a plain merge left the old
  one in charge: with `ZAMMAD_TOKEN` set, `from_env(user: 'u', password: 'p')` still sent
  the environment's token, and `client.with(oauth2_token: 'x')` on a token client went on
  acting as the account the token belonged to, with no error. Naming one way to authenticate
  now drops the others; overriding `password:` alone still keeps the `user` it pairs with.
  `Config#with` does the same.
- `pp config` redacts credentials, and a transport no longer prints its connection. `Config`
  is a `Data`, and `pp` — what IRB and the Rails console print a value with — has a printer
  of its own for those that renders the members without going through `inspect`, so
  `client.config` typed at a prompt showed the token, the password and a proxy's credentials
  in full. `Transport` had no `inspect` at all, so Ruby's default printed the Faraday
  connection it holds, proxy password and access token included, and every record holds its
  transport.
- A proxy or instance URL whose password carries an unencoded `/`, `?` or `#` is redacted.
  Each of those ends the authority early as far as URL syntax goes, so `proxy:
  'http://user:p#ss@proxy:3128'` left `user:p` as the authority, the redaction found no `@`
  in it, and the password was printed by `Config#inspect` and quoted in the
  `ConfigurationError` raised when the connection could not be built. Where a colon makes a
  password possible, everything up to the last `@` of the whole value is blanked now. The
  price is a URL with a port and an `@` further on, such as `https://host:8443/a@b`, which
  renders with its host blanked: a colon cannot tell a port from a password, and that is the
  mistake that leaks nothing.
- A wait before a retry is never longer than `timeout`. The retry middleware sleeps for
  whatever a `Retry-After` header says and has no ceiling of its own by default, so a
  maintenance page answering 503 or a rate limiter answering 429 with `Retry-After: 3600`
  held the calling thread for an hour per retry — two by default — before raising the error,
  whatever `timeout` and `retry_interval` said. A `Retry-After` within `timeout` is still
  honoured; a longer one is not waited out, and the request fails at once with the error for
  its status, `RateLimitError#retry_after` still carrying the figure.
- The test kit serves a sequence of list stubs one per read. Every full read of a collection
  asks for the page after its last one, and that request took the next stub in the queue and
  served it as an empty page: three stubs for `GET api/v1/groups` answered three reads with
  the first, the third and the third, and the second was never seen. A request for a later
  page is now answered by the stub its read began with and does not move the sequence on.
- An exceeded `open_timeout` raises `TimeoutError`. Net::HTTP reports it as
  `Net::OpenTimeout`, which Faraday's default adapter wraps into `Faraday::ConnectionFailed`
  with every other failure to connect, so it surfaced as `ConnectionError: … is unreachable
  (execution expired)` and skipped the `rescue ZammadAPI::TimeoutError` documented to catch
  it.
- A `dup` or `clone` of a record has a change set of its own. The attributes are frozen and
  replaced on write, but the change set is written in place and the copy shared it: after
  `copy = record.dup; copy.name = 'X'` the original reported `changed?` and a change to
  `name` while still reading `name` as it was, and its next `save` sent the copy's value.
  The copy also gets association readers of its own, rather than ones that read through the
  original.
- An attribute write on a destroyed record raises. `update` and `update!` already refused
  one, so as not to leave a change set that can never be sent, but the writers they are
  built on did not ask: `group.destroy; group.name = 'Z'` left `changed?` true and `name`
  reading `"Z"` on a record `destroy` promises to leave as it last was in Zammad, and the
  `save` after it was the first thing to object. A named writer, `[]=` and
  `assign_attributes` all refuse now, and stage nothing.
- A request body that cannot be encoded as JSON raises `ZammadAPI::Error`. Faraday's JSON
  middleware raised `JSON::GeneratorError` from inside the stack and nothing mapped it, so
  `client.post(path, body: {data: File.binread('a.png')})` with the bytes not
  Base64-encoded, or any body holding `Float::NAN`, went past the `rescue ZammadAPI::Error`
  callers are told to write — and so did a record `save` carrying such a value. The body is
  encoded before the request is logged now, so a refused one leaves no line claiming a
  request that was never made, and the test kit refuses it the same way.
- A walk no longer ends when the block empties the batch it was handed. The size of a page
  was read after the block returned, so an `in_batches` consumer that worked its batch off
  with `shift` looked like an empty page and the walk stopped after the first one, and a
  batch the block shortened looked like the last. The records are counted before they are
  handed over.
- A search is walked to its end where one of its pages comes back short. A walk stopped at
  the first page shorter than the one before it, which is right for an index and not for a
  search: Zammad has the search name the ids for a page and then loads the records by id,
  so one deleted in between, or one Elasticsearch still lists after it was removed, is left
  out and nothing fills its place. `search(...).each` then ended on that page with the
  rest of the hits unread, and `find_by` answered `nil` for a record on a later one. Only
  an empty page ends a search walk now, at the cost of one more request where the last page
  of hits is part-filled.
- A search is read on past a page with nothing on it where Zammad says there are hits
  behind it. A page comes back empty for the reason it comes back short, every id on it
  having lost its record, and on the page of one that `first` and `empty?` ask for a single
  stale hit does it: `search(term).first` answered `nil` and `empty?` answered `true` with
  live hits behind a record deleted a moment before, and `each` ended on such a page. A
  search that is walked sends `with_total_count` and ends on an empty page only once the
  pages read cover the total reported beside it. The total never ends a walk on a page that
  held records, because Elasticsearch stops counting at ten thousand hits. An empty page
  still ends the walk where there is no total to go by: on a Zammad before 7.0, which
  answers with the records alone, and past the ten thousandth hit on Elasticsearch. The
  test kit pages a search stubbed as `{records: [...], total_count: n}` the way it pages
  an Array.
- A repeated page is recognised by the records on it rather than by their payload. A job
  that writes to the records it is handed changes what they serialize as, so an endpoint
  that ignores `page` served the same records with a different payload each time: the
  guard never fired, and the job went round the same records, writing to them again, for
  as long as it ran. Two consecutive pages holding the same ids, in any order, raise
  `PaginationError` before the second is handed over. Records without an id are still
  compared by payload.
- A search sends the term and the filters it was given. The collection `search` returns is
  lazy and held the caller's own String, Array and Hash until it was enumerated, so
  `search('printer', ids: ids)` followed by `ids << 7` searched for something the call was
  never given, after the filters had been checked. `search` keeps a copy of its own, which
  `page` and `order` carry on.
- A `related` kept in a variable follows its record. A save, a reload and a write to a
  foreign key dropped the record's association proxy and built another on the next call, so
  only a caller who asked the record again saw the change: after `related = ticket.related`
  and `ticket.customer_id = 9`, `related.customer` went on answering with the user it had
  resolved before, and the same after a reload. A record keeps one proxy now and empties
  it. A kept one also refuses a destroyed record, as `related` does, where it used to
  answer from its memo and request the articles of a ticket that is gone. A lookup that is
  still on the wire when the foreign key is written, by a logger or a middleware that
  reaches the record or by another thread, no longer leaves the record it fetched behind as
  the answer for the new key. The proxy is emptied as well where a save answered with a 2xx
  nothing could read puts the record back on what it sent: a key written while that request
  was out, and an association read from it, left the record on the key it sent with the
  other key's record still the answer.
- Records of two Zammad instances are no longer equal for sharing a class and an id. An id
  is only unique within one installation, so a script reading two of them, such as a
  migration or a sync, held ticket 1 of each as one record: `uniq` dropped one of the two,
  and a Hash keyed by record answered for one instance with the other's value. `==`,
  `eql?` and `hash` take in the `url` the record's client was configured with. Two clients
  for one URL, and a client and its `on_behalf_of` scope, still hold the same record.
- An update Zammad acknowledged is not sent again. The staged changes were dropped only
  once the response had decoded, so an update answered with a 2xx nothing could read, such
  as a proxy's HTML page, raised `ParseError` with the whole change set still staged, and
  the next `save` sent all of it again along with whatever had been staged since. For a
  ticket's `article` that is a second article and a second e-mail. A 2xx now settles what
  was sent before the body is read: the record holds the values it sent with nothing
  staged, and `reload` brings in the rest. A save Zammad rejected keeps its changes staged,
  as before. What is settled is what the request carried: a write that reaches the record
  while the request is out, from a logger or a middleware that touches it or from another
  thread, is dropped, as it is by a response that can be read, rather than settled as if
  it had been sent. The body of the request is built from the same attributes it is then
  settled on, read once, so a write from another thread cannot land between the two and be
  sent without being settled. A key Zammad never served the record with is not kept either, which a
  ticket's `article` is: kept, the same article assigned again compared equal to the first
  and `save` reported `true` without sending the second reply.
- `ticket.add_article` adds to that ticket whatever its attributes say. A `ticket_id:`
  among them was replaced by the ticket's own, but only under the Symbol spelling: given
  `'ticket_id'` as well, the String key came later in the Hash and won when the article
  symbolized its keys, so the article was posted to the ticket the caller's Hash named.
  Both spellings are taken out before the ticket's id goes in.
- `on_behalf_of` keeps the user it was given. The scoped client held the caller's own
  String, so a login buffer reused after `client.on_behalf_of(login)` changed who every
  later request from that client was performed for. The scope is copied and frozen, in the
  test kit's transport as well.
- A proxy password no longer reaches an exception report through `cause`. The
  `ConfigurationError` for a connection that cannot be built had its message redacted, but
  Ruby attached the error it replaced as the cause, and a report prints the whole chain:
  `full_message`, a log formatter and an error tracker all showed `URI::InvalidURIError`
  quoting the proxy URL in full. The cause is dropped where its report would print a
  configured value that redaction changes, and kept everywhere else, so a `middleware:`
  callable that raises still shows the backtrace into the caller's code. An error that
  cannot render its report at all, such as one whose `detailed_message` takes no
  `highlight:` keyword, is dropped as a cause too, rather than leaving in place of the
  `ConfigurationError`.
- `middleware:` that adds `c.response :raise_error` is refused with a `ConfigurationError`
  when the client is built, as `c.response :json` already is. It sits below the retry
  middleware and raises for a 4xx or 5xx before this gem sees the response, so a `GET`
  answered 503 was not retried and left as `Faraday::ServerError`, a 404 left as
  `Faraday::ResourceNotFound`, which `exists?` does not rescue, and a 422 as an error
  `save` does not turn into `false`. None of them is a `ZammadAPI::Error`. A subclass of
  either middleware is refused as well: the stack was asked for the two by name, and
  `class QuietRaiseError < Faraday::Response::RaiseError` has another.
- A `Cookie` header is redacted in the debug log, and so is `Proxy-Authorization`. A raw
  request takes headers of its own and the request line prints them, and neither name
  matched the words that mark a credential, so `client.get(path, headers: {'Cookie' =>
  ...})` wrote the session out in full.

### Changed

- `Response#headers` is frozen, and each response carries its own. Writing through it
  changed nothing on the wire and, in `ZammadAPI::Test`, rewrote the stub for every later
  request in the example.

- `client.<resource>.destroy(id)` deletes directly instead of fetching the record first.
- Resource dispatch is explicit rather than `method_missing` plus `const_get`.
- A resource declares what its endpoint does — `searchable true`, `max_per_page 100`,
  `sortable false` — the way it already declared `path`, rather than by setting
  `SEARCHABLE`, `MAX_PER_PAGE` and `INDEX_QUERY_KEYS`. A misspelled constant was silently
  ignored and the resource kept Base's default, so `SEARCHEABLE = true` left the resource
  unsearchable and every `find_by` on it raised "Zammad routes no search endpoint" with no
  hint that the declaration was the problem; a misspelled declaration is a `NoMethodError`
  at load.
- `client.<resource>` returns the same proxy each time rather than allocating one per call.
  The proxies are built with the client and frozen, so a client stays immutable once built
  and safe to share between threads without locking, as documented. Clients from `#with`
  and `#on_behalf_of` get proxies of their own, so none is shared with the transport it was
  derived from.
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
