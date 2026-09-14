# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'fileutils'
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

desc 'Drive a live Zammad instance end to end with this gem (see TEST_URL)'
task :check_connection do
  sh 'ruby script/check_connection.rb'
end

RuboCop::RakeTask.new

desc 'Type-check lib/ against the signatures in sig/'
task :steep do
  sh 'bundle exec steep check'
end

# sig/vendor stands in for dependencies that ship no signatures and is kept
# out of the gem, so the published set has to hold up without it. Naming a
# Faraday type in a published signature made `rbs validate` fail for every
# consumer, and nothing in this repo noticed, because sig/vendor is always
# on the load path here.
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
