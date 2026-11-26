# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'fileutils'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require_relative 'script/live_target'

namespace :spec do
  desc 'Run the unit specs (no Zammad instance required)'
  RSpec::Core::RakeTask.new(:unit) do |task|
    task.pattern = 'spec/unit/**/*_spec.rb'
  end

  desc 'Run the integration specs against the Zammad that TEST_URL names'
  RSpec::Core::RakeTask.new(integration: :live_target) do |task|
    task.pattern = 'spec/integration/**/*_spec.rb'
  end
end

desc 'Run all specs'
task spec: [:live_target, 'spec:unit', 'spec:integration']

# The integration specs and check_connection create and delete records, so
# neither has a default for where. Asked here as well as in each of them, so
# that a task which was asked to run against a live Zammad says why it did
# not rather than passing over specs that were left out.
desc 'Check that TEST_URL names the Zammad to run the live checks against'
task :live_target do
  abort LiveTarget.unset_message('This task') if LiveTarget.url.nil?
end

desc 'Drive the Zammad that TEST_URL names end to end with this gem'
task check_connection: :live_target do
  sh 'ruby script/check_connection.rb'
end

RuboCop::RakeTask.new

desc 'Type-check lib/ against the signatures in sig/'
task :steep do
  sh 'bundle exec steep check'
end

# sig/vendor stands in for dependencies that ship no signatures and is kept
# out of the gem, so the published set has to hold up without it. Nothing
# else here notices a published signature that names a Faraday type, because
# sig/vendor is always on the load path in this repository.
desc 'Check that the signatures the gem ships validate without sig/vendor'
task :rbs_published do
  require 'tmpdir'

  Dir.mktmpdir do |dir|
    published = Dir['sig/**/*.rbs'].grep_v(%r{\Asig/vendor/})
    published.each do |file|
      target = File.join(dir, file)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(file, target)
    end
    # `logger` is the only library the published signatures name, and it is a
    # standard one RBS ships declarations for, so a consumer already has it.
    sh "bundle exec rbs -r logger -I #{File.join(dir, 'sig')} validate"
  end
end

desc 'Run everything that does not need a Zammad instance'
task default: ['spec:unit', :rubocop, :steep, :rbs_published]
