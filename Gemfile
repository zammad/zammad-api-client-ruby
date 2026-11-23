# frozen_string_literal: true

source 'https://rubygems.org'

# Runtime dependencies are defined in zammad_api.gemspec.
gemspec

group :development, :test do
  # For examples/ticket_report.rb. A bundled gem from Ruby 3.4 on, which
  # Bundler makes loadable only where the bundle names it. It was in the
  # bundle as a dependency of steep alone, and so not without that group.
  gem 'csv', require: false
  gem 'overcommit', require: false
  gem 'rake', require: false
  gem 'rspec', '~> 3.13'
  gem 'rubocop', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rake', require: false
  gem 'rubocop-rspec', require: false
  gem 'simplecov', '~> 1.3', require: false
  gem 'webmock', '~> 3.26'
  gem 'yard', require: false
end

group :development do
  # For bin/console. A bundled gem from Ruby 4.0 on, which Bundler makes
  # loadable only where the bundle names it.
  gem 'irb', require: false
  # Static type checking against the signatures in sig/.
  gem 'rbs', require: false
  gem 'steep', require: false
end
