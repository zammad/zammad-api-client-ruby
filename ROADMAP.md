# Features roadmap

What each Zammad API client models: this gem in its 1.x and 2.0 versions, and the
[PHP client](https://github.com/zammad/zammad-api-client-php).

✅ available · 🚧 work in progress · ❌ not available

## Resources

| Resource                  | Ruby 1.x | Ruby 2.0 | PHP                                                  |
| ------------------------- | :------: | :------: | ---------------------------------------------------- |
| Tickets                   | ✅       | ✅       | ✅                                                   |
| Ticket articles           | ✅       | ✅       | ✅ per ticket only, no index                         |
| Article attachments       | ✅       | ✅       | ✅ no class; `getAttachmentContent()` on the article |
| Ticket states             | ✅       | ✅       | ✅                                                   |
| Ticket priorities         | ✅       | ✅       | ✅                                                   |
| Users                     | ✅       | ✅       | ✅                                                   |
| Organizations             | ✅       | ✅       | ✅                                                   |
| Groups                    | ✅       | ✅       | ✅                                                   |
| Roles                     | ❌       | 🚧       | ✅                                                   |
| Tags                      | ❌       | 🚧       | ✅ list, search, add, remove                         |
| Links                     | ❌       | 🚧       | ✅ ticket to ticket                                  |
| Text modules              | ❌       | 🚧       | ✅                                                   |
| CSV import: users         | ❌       | 🚧       | ✅                                                   |
| CSV import: organizations | ❌       | 🚧       | ✅                                                   |
| CSV import: text modules  | ❌       | 🚧       | ✅                                                   |

Until a 🚧 row lands in Ruby 2.0, reach it by
[declaring a resource](README.md#declaring-a-resource) or with a
[raw request](README.md#raw-requests).

## Behaviour

| Behaviour                             | Ruby 1.x | Ruby 2.0                    | PHP                                              |
| ------------------------------------- | :------: | --------------------------- | ------------------------------------------------ |
| Auto-pagination                       | ❌       | ✅                          | ✅                                               |
| Total count of a search               | ❌       | ✅                          | ✅                                               |
| Sorted search                         | ❌       | ✅ not on tickets and users | ✅ as plain query parameters                     |
| Search by condition                   | ❌       | ✅                          | ❌                                               |
| Acting on behalf of a user            | ✅       | ✅                          | ✅ by wrapping the request handler               |
| Custom attributes                     | ✅       | ✅                          | ✅ tickets, users, organizations and groups only |
| Typed errors                          | ✅       | ✅                          | ✅                                               |
| Timeouts                              | ❌       | ✅                          | ✅                                               |
| Retry when rate limited               | ❌       | ✅ reads only               | ✅                                               |
| Retry on server and connection errors | ❌       | ✅ reads only               | ❌                                               |
| Attachment download as a stream       | ❌       | ❌                          | ❌                                               |
| Attachment upload helper              | ❌       | ❌                          | ❌ Base64 in the article                         |
| Test doubles for applications         | ❌       | ❌                          | ❌                                               |
| Framework integration                 | -       | -                          | ✅ Laravel, Symfony                              |

## Requested, not planned yet

What users ask for beyond the tables above, most requested first. Neither client
offers these today; all are reachable with a raw request. A row moves into a
table above once work on it starts.

| Request                                   | Where it was asked                                            |
| ----------------------------------------- | ------------------------------------------------------------- |
| Attachments: upload, stream, delete       | [PHP #4][php-4], community [10604][c-10604], [17478][c-17478], [13390][c-13390] |
| Listing beyond the 10,000 search limit    | community [10644][c-10644], [16162][c-16162], [zammad #768][z-768] |
| Time accounting                           | community [10244][c-10244], [7958][c-7958], [17492][c-17492]  |
| Knowledge base                            | [PHP #29][php-29], community [3510][c-3510], [12168][c-12168] |
| Tested Zammad versions per client release | [zammad #6561][z-6561], community [17422][c-17422]            |
| Find or create a user by exact email      | [PHP #9][php-9], [Ruby #6][ruby-6]                            |
| Ticket merge                              | community [4710][c-4710]                                      |
| Ticket history                            | community [10205][c-10205]                                    |
| Mentions, checklists, shared drafts       | community [15937][c-15937], [20651][c-20651]                  |
| Webhook signature verification            | community [9011][c-9011]                                      |

Missing something? Open an issue so we know what to model first.

[php-4]: https://github.com/zammad/zammad-api-client-php/issues/4
[php-9]: https://github.com/zammad/zammad-api-client-php/issues/9
[php-29]: https://github.com/zammad/zammad-api-client-php/issues/29
[ruby-6]: https://github.com/zammad/zammad-api-client-ruby/issues/6
[z-768]: https://github.com/zammad/zammad/issues/768
[z-6561]: https://github.com/zammad/zammad/issues/6561
[c-3510]: https://community.zammad.org/t/3510
[c-4710]: https://community.zammad.org/t/4710
[c-7958]: https://community.zammad.org/t/7958
[c-9011]: https://community.zammad.org/t/9011
[c-10205]: https://community.zammad.org/t/10205
[c-10244]: https://community.zammad.org/t/10244
[c-10604]: https://community.zammad.org/t/10604
[c-10644]: https://community.zammad.org/t/10644
[c-12168]: https://community.zammad.org/t/12168
[c-13390]: https://community.zammad.org/t/13390
[c-15937]: https://community.zammad.org/t/15937
[c-16162]: https://community.zammad.org/t/16162
[c-17422]: https://community.zammad.org/t/17422
[c-17478]: https://community.zammad.org/t/17478
[c-17492]: https://community.zammad.org/t/17492
[c-20651]: https://community.zammad.org/t/20651
