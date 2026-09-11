# Examples

Runnable scripts showing how the 2.0 API works in a real project. Each one is
self-contained and builds its client with `ZammadAPI::Client.from_env`, which
reads the credentials from the environment:

```sh
export ZAMMAD_URL=https://zammad.example.com/
export ZAMMAD_TOKEN=your-access-token

ruby examples/quickstart.rb
```

`ZAMMAD_USER` and `ZAMMAD_PASSWORD` work instead of a token, as does
`ZAMMAD_OAUTH2_TOKEN`.

> These scripts **create, modify and delete records**. Point them at a
> disposable instance.

None of them set a timeout or a retry policy: requests time out after 60s and
transient failures are retried with backoff out of the box, so the examples
show what is left for your own code to do.

| Script | What it does | API features it shows |
| ------ | ------------ | --------------------- |
| [`quickstart.rb`](quickstart.rb) | Creates a ticket, reads it back, adds an article, updates it | The basics end to end |
| [`pagination.rb`](pagination.rb) | Reads a collection every available way | `each`, `find_each`, `in_batches`, `page(n, of: m)`, `where`, `count`, `empty?`, `lazy`, `first(n)`, collection immutability |
| [`manual_batches.rb`](manual_batches.rb) | Drives pagination by hand: pull-based, numbered, resumable | `in_batches` as an Enumerator (`next`, `with_index`), an explicit `page(n, of: m)` loop with a persisted cursor |
| [`ticket_report.rb`](ticket_report.rb) | Exports every ticket to CSV | Automatic pagination, `in_batches` batching, `fetch` for required attributes |
| [`triage_tickets.rb`](triage_tickets.rb) | Flags urgent tickets, nudges stale ones | `search`, `case/in` pattern matching on records, staged `changes` so only diffs are sent, `article` |
| [`onboard_customer.rb`](onboard_customer.rb) | Creates an organization, a user, and a welcome ticket raised as that user | `find_by`, `create`, `on_behalf_of` as a scoped client and as a block |
| [`download_attachments.rb`](download_attachments.rb) | Saves a ticket's attachments to disk | `articles`, attachment metadata, binary-safe `download` |
| [`error_handling.rb`](error_handling.rb) | Handles the failures that are yours to handle | The error hierarchy, `save` → `false` with `record.error`, rescuing by category, `client.with` for different retry settings |
| [`concurrent_sync.rb`](concurrent_sync.rb) | Syncs tickets with a worker pool sharing one client | Immutable clients are thread-safe; also sketches the Rails initializer pattern |

The examples are linted along with the rest of the repository (`rake rubocop`),
so they cannot silently rot.
