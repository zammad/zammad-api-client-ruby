require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

unless ENV['CI']
  RSpec::Core::RakeTask.new(:spec)

  task default: :spec
end