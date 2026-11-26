# Upgrading from 1.x

Version 2.0 fixes long-standing behaviour that could not change without breaking
compatibility. Most calling code needs one rename: the resource names are plural, so
`client.ticket` is `client.tickets`. Almost everything else that needs an edit raises at
the call site. Start with the few changes that do not.

If this is not the time to move, [1.x stays available](#staying-on-1x).

## Silent changes

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

- **`collection.each`** reads every page, where 1.x stopped after the first (100 records
  for `all`, 10 for `search`). A loop that used to touch the first 100 tickets now touches
  all of them. To keep the old limit, use `first(n)` or `page(1, per_page: n)`.

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

## The client

| 1.x                                    | 2.0                                              | Why                                                                  |
| -------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------- |
| `Client.new(config_hash)`              | `Client.new(**config_hash)`                      | Options are keyword arguments now, so a Hash has to be splatted      |
| an unknown option was ignored          | raises `ArgumentError: unknown keyword`          | A typo'd option used to be dropped without a word                    |
| `logger: true`                         | `logger: Logger.new($stderr)`                    | The flag became an object. Anything that responds to `debug` works |
| `client.ticket`, `client.user`, …      | `client.tickets`, `client.users`, …              | A resource is every record of its kind. The singular names raise `UnknownResourceError` |
| `client.on_behalf_of = 'login'`        | `client.on_behalf_of('login')` → new client      | The setter mutated the client and leaked across threads              |
| `client.perform_on_behalf_of('x') { }` | `client.on_behalf_of('x') { \|scoped\| ... }`    | The old block form left the header set if the block raised           |
| `ZammadAPI::Resources::Role < Base` reached by `client.role` | `client.resource(Role)`, for a `Role < ZammadAPI::Resources::Base` of your own | The named readers are a fixed list. [Raw requests][raw-requests] reach whatever is not a resource |

## Collections

| 1.x                                      | 2.0                                              | Why                                                                 |
| ---------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------- |
| `collection.page(1, 3) { \|r\| ... }`    | `collection.page(1, per_page: 3).each { ... }`         | `page` now returns a collection instead of mutating and yielding    |
| `collection.page_next` / `page_prev`     | `collection.page(n)` or `in_batches`             | Removed; they mutated shared state                                  |
| `collection[3]`                          | `collection.page(4, per_page: 1).first`                | An index that costs a request, and that ignored `page`, was a trap  |
| `collection.find(1)`                     | `client.x.find(1)`, or `collection.detect { ... }` | `find` on a collection is `Enumerable#find`; an id raises `ArgumentError` |
| `client.x.all(per_page: 50)`             | `client.x.all.page(1, per_page: 50)`, `find_each(batch_size: 50)` | `all` accepted the argument and discarded it; page size belongs to the call that reads |
| `client.x.all(active: true)`             | `client.x.search(...)`, or `client.x.all.detect { ... }`    | Zammad's index endpoints do not filter, so 1.x ignored the argument |
| `client.x.search(query: 'zammad')`       | `client.x.search('zammad')`                      | The search term is the argument, not a keyword                      |
| `client.x.search(query: 'z', page: 2, per_page: 50)` | `client.x.search('z').page(2, per_page: 50)` | Search did honour those two; paging is the collection's job now     |

## Records

| 1.x                                 | 2.0                                                  | Why                                                                  |
| ----------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------- |
| `record.attributes[:x] = 1`         | `record.x = 1`, or `record.to_h` for a copy          | Writing through the reader staged no change, so `save` never sent it  |
| `record.id = 5`                     | `client.x.find(5)`                                   | The id addresses the record, so a staged one deleted or updated a different record than it reported. It raises `ZammadAPI::Error` now |
| `record.new_instance`               | `record.new_record?` / `record.persisted?`           | Internal flag is no longer public; the old name raises `NoMethodError` |
| `resource.url` (instance)           | `Resource.resource_path` (class)                     | Clashed with an attribute named `url`                                |
| `record.unknown_attribute` → `nil`  | raises `NoMethodError`; use `record[:x]`, `fetch(:x, nil)` or `key?(:x)` | A typo used to read as `nil` |
| `ticket.article(body: '…')`         | `ticket.add_article(body: '…')`                      | Renamed; `ticket.article(...)` raises `NoMethodError` |

## Errors

| 1.x                                   | 2.0                                                  | Why                                                             |
| ------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------- |
| `ZammadAPI::Error < RuntimeError`     | `ZammadAPI::Error < StandardError`                   | `RuntimeError` is for `raise "string"`                          |
| `ZammadAPI::ResourceNotFoundError`    | `ZammadAPI::UnknownResourceError`                    | Renamed so it is not confused with a 404, now `NotFoundError`   |
| `ClientError` for every 4xx           | `AuthenticationError`, `NotFoundError`, `ValidationError`, … | All still `ClientError`, so existing rescues keep working |
| `error.response` was a Faraday object | `ZammadAPI::Response` with `status`/`body`/`headers` | Faraday is no longer part of the public surface                 |
| `error.body` was a raw JSON string    | decoded Hash, or the raw body for non-JSON           | Saves every caller from parsing it again                        |

## Removed constants, and the Ruby version

| 1.x                                              | 2.0                        | Why                                                          |
| ------------------------------------------------ | -------------------------- | ------------------------------------------------------------ |
| `ZammadAPI::ListBase` / `ListAll` / `ListSearch` | `ZammadAPI::Collection`    | One class instead of three                                   |
| `ZammadAPI::Dispatcher`                          | `ZammadAPI::ResourceProxy` | Renamed; `client.<resource>` hands you one                   |
| `ZammadAPI::Log`, `ZammadAPI::JsonHelper`        | removed                    | Pass any `Logger` as `logger:`; decoding moved into the transport |
| Ruby >= 3.0                                      | Ruby >= 3.4                | 3.0 through 3.3 are end-of-life or nearly so                 |

## New defaults

A collection fetches as many records per request as the endpoint serves: 1000 on most
index endpoints (1.x: 100), 100 on tickets (unchanged) and 200 on a search (1.x: 10).
`page(n)` without `per_page:` is a page of that size, so pin it with
`page(n, per_page: 100)` if a persisted page number has to keep meaning what it did.

A request times out after 60 seconds (10 to connect), where 1.x waited as long as the
server took. A call that used to hang raises `ZammadAPI::TimeoutError`, or
`ZammadAPI::ConnectionError` when the connection is not opened in time. A `GET` is retried
twice with exponential backoff on connection failures, timeouts and the transient
statuses; a `POST`, `PUT` or `DELETE` is never retried. Both are options: see
[Timeouts and retries][timeouts-and-retries]. The `User-Agent` is
`zammad_api-ruby/<version>` rather than `Zammad API Ruby`.

## What did not change

`find`, `all`, `create` and `new` on a resource, `record.destroy`, attribute readers and
writers, `ticket.articles` and `attachment.download`.

`record.save`, `record.changes` and `record.attributes` still exist and still mean what
they meant; the tables above only change how they behave at the edges.

## Staying on 1.x

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

[raw-requests]: https://github.com/zammad/zammad-api-client-ruby/blob/master/README.md#raw-requests
[timeouts-and-retries]: https://github.com/zammad/zammad-api-client-ruby/blob/master/README.md#timeouts-and-retries
