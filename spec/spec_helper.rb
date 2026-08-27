# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    enable_coverage :branch
    add_filter '/spec/'
    minimum_coverage line: 90, branch: 75
  end
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Unit specs run entirely against stubs; integration specs opt back out below.
require 'webmock/rspec'
require 'zammad_api'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { require it }

RSpec.configure do |config|
  config.include ClientHelper

  config.expect_with(:rspec) { it.syntax = :expect }
  config.mock_with(:rspec) { it.verify_partial_doubles = true }

  config.disable_monkey_patching!
  config.warnings = false
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'tmp/rspec_status.txt'
  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Specs are grouped by what they need: unit specs run against WebMock stubs
  # and never touch the network, integration specs need a live Zammad.
  config.define_derived_metadata(file_path: %r{/spec/unit/}) { it[:unit] = true }
  config.define_derived_metadata(file_path: %r{/spec/integration/}) { it[:integration] = true }

  # Integration specs need the real network, so WebMock steps aside for them.
  config.around(:each, :integration) do |example|
    WebMock.allow_net_connect!
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
    WebMock.disable_net_connect!
  end
end
