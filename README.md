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
* ticket_article
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

## perform actions on behalf of other user

As described in the [Zammad API documentation](https://docs.zammad.org/en/latest/api-intro.html#example-curl-request-on-behalf-of-a-different-user) it is possible to perfom actions on behalf other users. To use this feature you can set the attribute of the client accordingly:

```ruby
client.on_behalf_of = 'some_login'
```

All following actions with the client will be performed on behalf of the user with the `login` "some_login".

To reset this back to regular requests just set `nil`:

```ruby
client.on_behalf_of = nil
```

It's possible to perform only a block of actions on behalf of another user via:

```ruby
client.perform_on_behalf_of('some_login') do
  # ticket is created on behalf of the user with
  # the login "some_login"
  client.ticket.create(
    ...
  )
end

# further actions are performed regularly.
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
    # attachments can be optional, data needs to be base64 encoded
    attachments: [
      'filename' => 'some_file.txt',
      'data' => 'dGVzdCAxMjM=',
      'mime-type' => 'text/plain',
    ],
  },
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

get all articles of a ticket
```ruby
ticket = client.ticket.find(123)
articles = ticket.articles

articles[0].id # id of record
articles[0].from # creator of article
articles[0].to # recipients of article
articles[0].subject # article subject
articles[0].body # text of message
articles[0].content_type # text/plain or text/html of .body
articles[0].type # 'note'
articles[0].sender # 'Customer'
articles[0].created_at # '2022-01-01T12:42:01Z'

p "ticket: #{ticket.number} - #{ticket.title}"
articles.each {|article|
  p "article: #{article.from} - #{article.subject}"
}
```

create an article for a ticket
```ruby
ticket = client.ticket.find(123)

article = ticket.article(
  type: 'note',
  subject: 'some subject 2',
  body: 'some body 2',
  # attachments can be optional, data needs to be base64 encoded
  attachments: [
    'filename' => 'some_file.txt',
    'data' => 'dGVzdCAxMjM=',
    'mime-type' => 'text/plain',
  ],
)

article.id # id of record
article.from # creator of article
article.to # recipients of article
article.subject # article subject
article.body # text of message
article.content_type # text/plain or text/html of .body
article.type # 'note'
article.sender # 'Customer'
article.created_at # '2022-01-01T12:42:01Z'
article.attachments.each { |attachment|
  attachment.filename # 'some_file.txt'
  attachment.size # 1234
  attachment.preferences # { :"Mime-Type"=>"image/jpeg" }
  attachment.download # content of attachment / extra REST call will be executed
}

p "article: #{article.from} - #{article.subject}"
```

create an article with html and inline images for a ticket
```ruby
ticket = client.ticket.find(123)

article = ticket.article(
  type: 'note',
  subject: 'some subject 2',
  body: 'some <b>body</b> with an image <img src="data:image/jpeg;base64,/9j/4QAYRXhpZgAASUkqAAgAAAAAAAAAAAAAAP/sABFEdWNreQABAAQAAAAJAAD/4QMtaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wLwA8P3hwYWNrZXQgYmVnaW49Iu+7vyIgaWQ9Ilc1TTBNcENlaGlIenJlU3pOVGN6a2M5ZCI/PiA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4OnhtcHRrPSJBZG9iZSBYTVAgQ29yZSA1LjMtYzAxMSA2Ni4xNDU2NjEsIDIwMTIvMDIvMDYtMTQ6NTY6MjcgICAgICAgICI+IDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+IDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PSIiIHhtbG5zOnhtcD0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wLyIgeG1sbnM6eG1wTU09Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9tbS8iIHhtbG5zOnN0UmVmPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvc1R5cGUvUmVzb3VyY2VSZWYjIiB4bXA6Q3JlYXRvclRvb2w9IkFkb2JlIFBob3Rvc2hvcCBDUzYgKE1hY2ludG9zaCkiIHhtcE1NOkluc3RhbmNlSUQ9InhtcC5paWQ6QzJCOTE2NzlGQUEwMTFFNjg0M0NGQjU0OUU4MTFEOEIiIHhtcE1NOkRvY3VtZW50SUQ9InhtcC5kaWQ6QzJCOTE2N0FGQUEwMTFFNjg0M0NGQjU0OUU4MTFEOEIiPiA8eG1wTU06RGVyaXZlZEZyb20gc3RSZWY6aW5zdGFuY2VJRD0ieG1wLmlpZDpDMkI5MTY3N0ZBQTAxMUU2ODQzQ0ZCNTQ5RTgxMUQ4QiIgc3RSZWY6ZG9jdW1lbnRJRD0ieG1wLmRpZDpDMkI5MTY3OEZBQTAxMUU2ODQzQ0ZCNTQ5RTgxMUQ4QiIvPiA8L3JkZjpEZXNjcmlwdGlvbj4gPC9yZGY6UkRGPiA8L3g6eG1wbWV0YT4gPD94cGFja2V0IGVuZD0iciI/Pv/uAA5BZG9iZQBkwAAAAAH/2wCEABQRERoTGioZGSo1KCEoNTEpKCgpMUE4ODg4OEFEREREREREREREREREREREREREREREREREREREREREREREREQBFhoaIh0iKRoaKTkpIik5RDktLTlEREREOERERERERERERERERERERERERERERERERERERERERERERERERERERP/AABEIABAADAMBIgACEQEDEQH/xABbAAEBAAAAAAAAAAAAAAAAAAAEBQEBAQAAAAAAAAAAAAAAAAAABAUQAAEEAgMAAAAAAAAAAAAAAAABAhIDESIxBAURAAICAwAAAAAAAAAAAAAAAAESABNRoQP/2gAMAwEAAhEDEQA/AJDq1rfF3Imeg/1+lFy2oR564DKWWWbweV+Buf/Z" alt="Red dot" />',
  content_type: 'text/html', # optional, default is text/plain
)

article.id # id of record
article.from # creator of article
article.to # recipients of article
article.subject # article subject
article.body # text of message
article.content_type # text/plain or text/html of .body
article.type # 'note'
article.sender # 'Customer'
article.created_at # '2022-01-01T12:42:01Z'
article.attachments.each { |attachment|
  attachment.filename # '122.146472496@www.znuny.com'
  attachment.size # 1167
  attachment.preferences # { :'Mime-Type'=>'image/jpeg', :'Content-ID'=>'122.146472496@www.znuny.com', :'Content-Disposition'=>'inline'} }
  attachment.download # content of attachment / extra REST call will be executed
}

p "article: #{article.from} - #{article.subject}"
```

## Testing

### setup an (empty Zammad) test env

```
git clone git@github.com:zammad/zammad.git
cd zammad
export RAILS_ENV="test"
export APP_RESTART_CMD="bundle exec rake zammad:ci:app:restart"
script/bootstrap.sh && echo '' > log/test.log
cp contrib/auto_wizard_test.json auto_wizard.json
bundle exec rake zammad:ci:test:start
```

### execute client tests

Run tests via `rake spec`. (Remember to export the vars above if you are running this in another shell.)

## Publishing

```
gem build -o pkg/zammad_api-1.0.6.gem zammad_api.gemspec
gem push pkg/zammad_api-1.0.6.gem
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/zammad/zammad-api-client-ruby. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.
