# Zammad API Client (Ruby)

## API version support
This client supports Zammad version 1.0 API.

## Installation

The Zammad API client can be installed using Rubygems or Bundler.

```ruby
gem install zammad_api
```

or add the following to your Gemfile

```ruby
gem 'zammad_api'
```

## Available objects

* user
* organization
* group
* ticket
* ticket_state
* ticket_priority

## Usage

### create instanze

```ruby
client = ZammadAPI::Client.new(
  url: 'http://localhost:3000/',
  user: 'user',
  password: 'some_pass'
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
  priority: '3 normal',
  article: {
    content_type: 'text/plain', # or text/html
    body: 'some body'
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

* git clone git@github.com:zammad/zammad.git
* cd zammad
* cp contrib/auto_wizard_test.json auto_wizard.json
* ./script/bootstrap.sh
* rails s

### execute client tests

* rspec spec/zammad_api_spec.rb
