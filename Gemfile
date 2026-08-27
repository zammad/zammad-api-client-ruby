# frozen_string_literal: true

source 'https://rubygems.org'

# Runtime dependencies are defined in zammad_api.gemspec.
gemspec

group :development, :test do
  gem 'overcommit', require: false
  gem 'rake', require: false
  gem 'rspec', '~> 3.13'
  gem 'rubocop', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rake', require: false
  gem 'rubocop-rspec', require: false
  gem 'simplecov', '~> 0.22', require: false
  gem 'webmock', '~> 3.26'
  gem 'yard', require: false
end

group :development do
  # Static type checking against the signatures in sig/.
  gem 'rbs', require: false
  gem 'steep', require: false
end
