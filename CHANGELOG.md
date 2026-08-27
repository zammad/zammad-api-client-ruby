# Changelog

## [2.0.0] - 2026-08-27

A breaking release that modernises the whole gem. See
[Migrating from 1.x](README.md#migrating-from-1x) for a complete before/after table.

### Breaking

- Minimum Ruby version is now 3.4.
- `Collection#each` (`client.x.all`, `client.x.search`) now walks every page. Previously it
  fetched a single page, so iterating silently stopped at 100 records.
- `page(number, per_page)` with a block was replaced by `page(number, per_page:)`, which
  returns a new collection. `page_next` and `page_prev` were removed; use `page` or the new
  `each_page`.
- `client.on_behalf_of = 'login'` and `client.perform_on_behalf_of` were replaced by
  `client.on_behalf_of('login')`, which returns a new client and also accepts a block.
- `ZammadAPI::ResourceNotFoundError` is now `ZammadAPI::UnknownResourceError`, freeing the
  404 case to be `ZammadAPI::NotFoundError`.
- `ZammadAPI::Error` descends from `StandardError` instead of `RuntimeError`.
- `ResponseError#response` returns a `ZammadAPI::Response`, not a Faraday object, and
  `#body` is the decoded payload rather than a raw JSON string.
- `ZammadAPI::ListBase`, `ListAll` and `ListSearch` were replaced by `ZammadAPI::Collection`.
- `ZammadAPI::Log` and `ZammadAPI::JsonHelper` were removed. Pass any `Logger` via `logger:`.
- The internal `new_instance` accessor was replaced by `new_record?` and `persisted?`, and
  the instance-level `url` accessor by the class-level `resource_path`.

### Added

- Request and connection timeouts (`timeout`, `open_timeout`), on by default.
- Automatic retry with exponential backoff for idempotent requests on connection failures,
  timeouts and transient statuses. `POST` is never retried, so a failed create cannot
  produce duplicate records.
- A specific error class per status: `AuthenticationError` (401), `AuthorizationError`
  (403), `NotFoundError` (404), `ValidationError` (422) and `RateLimitError` (429, with
  `#retry_after`). Network failures raise `ConnectionError` or `TimeoutError` instead of
  leaking Faraday exceptions.
- `Collection#each_page`, `#where` and lazy enumeration.
- `Base#reload`, `#persisted?`, `#[]`, `#fetch`, `#to_h` and a readable `#inspect`.
- `ssl_verify`, `proxy`, `user_agent`, `retries` and `retry_interval` client options.
- RBS signatures in `sig/`, verified by Steep in CI.
- `respond_to?` now answers correctly for attribute readers and resource methods.

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

### Changed

- `client.<resource>.destroy(id)` deletes directly instead of fetching the record first.
- Resource dispatch is explicit rather than `method_missing` plus `const_get`.
- Unit specs (`rake spec:unit`) run without a Zammad instance; the specs that need a live
  server live in `spec/integration`.
- CI runs RuboCop, Steep and the unit specs on Ruby 3.4, 3.5 and head, and publishes
  releases through RubyGems trusted publishing.

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
