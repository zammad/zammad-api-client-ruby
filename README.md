# Zammad API Client (Ruby)

## API version support
This client supports Zammad API version 1.0.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'zammad_api'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install zammad_api

## Available objects

* user
* organization
* group
* ticket
* ticket_state
* ticket_priority

## Usage

### create instance

#### username/email and password

```ruby
client = ZammadAPI::Client.new(
  url:      'http://localhost:3000/',
  user:     'user',
  password: 'some_pass'
)
```

#### access token

```ruby
client = ZammadAPI::Client.new(
  url:        'http://localhost:3000/',
  http_token: '12345678901234567890',
)
```

#### OAuth2

```ruby
client = ZammadAPI::Client.new(
  url:          'http://localhost:3000/',
  oauth2_token: '12345678901234567890',
)
```

## Resource management

Individual resources can be created, modified, saved, and destroyed.

### create object

with new and save
```ruby
group = client.group.new(
  name: 'Support',
  note: 'Some note',
);
group.save

group.id # id of record
group.name # 'Support'
```

with create
```ruby
group = client.group.create(
  name: 'Support',
  note: 'Some note',
);

group.id # id of record
group.name # 'Support'
```

### fetch object

```ruby
group = client.group.find(123)
puts group.inspect
```
### update object

```ruby
group = client.group.find(123)
group.name = 'Support 2'
group.save
```

### destroy object

```ruby
group = client.group.find(123)
group.destroy
```

## Collection management

A list of individual resources.

### all

```ruby
groups = client.group.all

group1 = groups[0]
group1.note = 'Some note'
group1.save

groups.each {|group|
  p "group: #{group.name}"
}
```

### search
```ruby
groups = client.group.search(query: 'some name')

group1 = groups[0]
group1.note = 'Some note'
group1.save

groups.each {|group|
  p "group: #{group.name}"
}
```

### all with pagination (beta)

```ruby
groups = client.group.all

groups.page(1,3) {|group|
  p "group: #{group.name}"

  group.note = 'Some new note, inclued in page 1 with 3 per page'
  group.save
}

groups.page(2,3) {|group|
  p "group: #{group.name}"

  group.note = 'Some new note, inclued in page 2 with 3 per page'
  group.save
}
```

### search with pagination (beta)
```ruby
groups = client.group.search(query: 'some name')

groups.page(1,3) {|group|
  p "group: #{group.name}"

  group.note = 'Some new note, inclued in page 1 with 3 per page'
  group.save
}

groups.page(2,3) {|group|
  p "group: #{group.name}"

  group.note = 'Some new note, inclued in page 2 with 3 per page'
  group.save
}
```

## Examples

create ticket
```ruby
ticket = client.ticket.create(
  title: 'a new ticket #1',
  state: 'new',
  group: 'Users',
  priority: '2 normal',
  customer: 'some_customer@example.com',
  article: {
    content_type: 'text/plain', # or text/html, if not given test/plain is used
    body: 'some body',
  }
)

ticket.id # id of record
ticket.number # uniq number of ticket
ticket.title # 'a new ticket #1'
ticket.group # 'Support'
ticket.created_at # '2022-01-01T12:42:01Z'
# ...
```

list of all new or open
```ruby
tickets = client.ticket.search(query: 'state:new OR state:open')

ticket[0].id # id of record
ticket[0].number # uniq number of ticket
ticket[0].title # 'title of ticket'
ticket[0].group # 'Support'
ticket[0].created_at # '2022-01-01T12:42:01Z'

tickets.each {|ticket|
  p "ticket: #{ticket.number} - #{ticket.title}"
}
```

## Testing

### setup an (empty Zammad) test env

```
git clone git@github.com:zammad/zammad.git
cd zammad

export RAILS_ENV=test
export WS_PORT=6042
export BROWSER_PORT=3001
export IP=localhost
export TEST_URL=http://$IP:$BROWSER_PORT

script/build/test_startup.sh $RAILS_ENV $BROWSER_PORT $WS_PORT 1
cp contrib/auto_wizard_test.json auto_wizard.json
```

### execute client tests

Run tests via `rake spec`. (Remember to export the vars above if you are running this in another shell.)

Cleanup your test system with `script/build/test_shutdown.sh $RAILS_ENV $BROWSER_PORT $WS_PORT 0 1` after the tests have run.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/martini/zammad_api_client_ruby. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.
