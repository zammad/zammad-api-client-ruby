#!/usr/bin/env ruby

$LOAD_PATH << './lib'
require 'rubygems'
require 'zammad_api'

client = ZammadAPI::Client.new(
  url: 'https://you.zammad.com/',
  http_token: 'XXXX',
)

# create ticket
ticket = client.ticket.new(
  title: 'some new title',
  state: 'new',
  priority: '2 normal',
  owner: '-',
  customer: 'nicole.braun@zammad.org',
  group: 'Users',
  article: {
    sender: 'Customer',
    type: 'note',
    subject: 'some subject',
    content_type: 'text/plain',
    body: "some body\nnext line",
  }
)
ticket.save

p '--------------------------------------------------------'
p "Ticket has been created: #{ticket.number} - #{ticket.title} at #{ticket.created_at}"
p " Attributes: #{ticket.attributes.inspect}"

# get ticket
p '--------------------------------------------------------'
ticket = client.ticket.find(ticket.id)
p "Ticket found on server: #{ticket.number} - #{ticket.title} at #{ticket.created_at}"
p " Attributes: #{ticket.attributes.inspect}"

# get articles of ticket
p '--------------------------------------------------------'
articles = ticket.articles
p "Total #{articles.length} articles"

# create article
p '--------------------------------------------------------'
article = ticket.article(
  type: 'note',
  subject: 'some subject 2',
  body: 'some body 2',
)
p "Article has been created: #{article.subject} at #{article.created_at}"
p " Attributes: #{article.attributes.inspect}"

# get articles of ticket
p '--------------------------------------------------------'
articles = ticket.articles
p "Total #{articles.length} articles now"
p '--------------------------------------------------------'
