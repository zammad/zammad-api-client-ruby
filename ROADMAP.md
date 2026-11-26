# Features roadmap

What each Zammad API client models: this gem in its 1.x and 2.0 versions, and the
[PHP client](https://github.com/zammad/zammad-api-client-php).

✅ available · 🚧 work in progress · ❌ not available

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
| Tags                      | ❌       | 🚧       | ✅ list, search, add, remove                         |
| Links                     | ❌       | 🚧       | ✅ ticket to ticket                                  |
| Text modules              | ❌       | 🚧       | ✅                                                   |
| CSV import: users         | ❌       | 🚧       | ✅                                                   |
| CSV import: organizations | ❌       | 🚧       | ✅                                                   |
| CSV import: text modules  | ❌       | 🚧       | ✅                                                   |

Until a 🚧 row lands in Ruby 2.0, reach it by
[declaring a resource](README.md#declaring-a-resource) or with a
[raw request](README.md#raw-requests).
