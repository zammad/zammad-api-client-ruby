# Examples

Runnable scripts showing how the 2.0 API works in a real project. Each is
self-contained and reads its credentials from the environment:

```sh
export ZAMMAD_URL=https://zammad.example.com/
export ZAMMAD_TOKEN=your-access-token

ruby examples/ticket_report.rb tickets.csv
```

> These scripts **create, modify and delete records**. Point them at a
> disposable instance.

| Script | What it does | API features it shows |
| ------ | ------------ | --------------------- |
| [`example_http_token.rb`](example_http_token.rb) | Creates a ticket, reads it back, adds an article | The basics end to end |
| [`pagination.rb`](pagination.rb) | Walks a collection every available way and prints the HTTP cost of each | `each`, `each_page`, `page`, `where`, `[]`, `lazy`, `first(n)`, and collection immutability |
| [`ticket_report.rb`](ticket_report.rb) | Exports every ticket to CSV | Automatic pagination, `each_page` batching, `client.with` for a long-running job, `fetch` for required attributes |
| [`triage_tickets.rb`](triage_tickets.rb) | Escalates urgent tickets, nudges stale ones | `search`, `lazy` early exit, `case/in` pattern matching on records, staged `changes` so only diffs are sent, `article` |
| [`onboard_customer.rb`](onboard_customer.rb) | Creates an organization, a user, and a welcome ticket raised as that user | `create`, `on_behalf_of` as a scoped client and as a block |
| [`download_attachments.rb`](download_attachments.rb) | Saves a ticket's attachments to disk | `articles`, attachment metadata, binary-safe `download` |
| [`error_handling.rb`](error_handling.rb) | Handles every failure the gem can raise | The full error hierarchy, `RateLimitError#retry_after`, `server_message`, early `ConfigurationError` |
| [`concurrent_sync.rb`](concurrent_sync.rb) | Syncs tickets with a worker pool sharing one client | Immutable clients are thread-safe; also sketches the Rails initializer pattern |

The examples are linted along with the rest of the repository (`rake rubocop`),
so they cannot silently rot.
