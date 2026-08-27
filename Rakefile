# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

namespace :spec do
  desc 'Run the unit specs (no Zammad instance required)'
  RSpec::Core::RakeTask.new(:unit) do |task|
    task.pattern = 'spec/unit/**/*_spec.rb'
  end

  desc 'Run the integration specs against a live Zammad (see TEST_URL)'
  RSpec::Core::RakeTask.new(:integration) do |task|
    task.pattern = 'spec/integration/**/*_spec.rb'
  end
end

desc 'Run all specs'
task spec: ['spec:unit', 'spec:integration']

RuboCop::RakeTask.new

desc 'Type-check lib/ against the signatures in sig/'
task :steep do
  sh 'bundle exec steep check'
end

desc 'Run everything that does not need a Zammad instance'
task default: ['spec:unit', :rubocop, :steep]
