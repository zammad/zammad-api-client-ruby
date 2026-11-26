# Contributing

```sh
bin/setup            # bundle install, plus the overcommit git hooks
bundle exec rake     # unit specs, RuboCop, Steep and the shipped signatures
```

| Task                     | What it does                                          |
| ------------------------ | ----------------------------------------------------- |
| `rake spec:unit`         | Unit specs; stubbed, no Zammad needed                 |
| `rake spec:integration`  | Integration specs against a live Zammad               |
| `rake spec`              | Both; needs `TEST_URL`, like the integration specs    |
| `rake check_connection`  | Drives a live Zammad end to end and prints a transcript |
| `rake rubocop`           | Style checks                                          |
| `rake steep`             | Type-check `lib/` against `sig/`, and `spec/typed/` the way a caller is checked |
| `rake rbs_published`     | Validate the signatures the gem ships, without `sig/vendor/` |

Set `COVERAGE=true` to produce a coverage report in `coverage/`.

## Testing against a live Zammad

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
