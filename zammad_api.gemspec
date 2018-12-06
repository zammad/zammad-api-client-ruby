# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'zammad_api/version'

Gem::Specification.new do |spec|
  spec.name          = 'zammad_api'
  spec.version       = ZammadAPI::VERSION.dup
  spec.authors       = ['Martin Edenhofer', 'Thorsten Eckel']
  spec.email         = ['support@zammad.org']

  spec.summary       = 'Zammad API v1.0 client.'
  spec.description   = 'Ruby wrapper for the Zammad API v1.0.'
  spec.homepage      = 'https://github.com/zammad/zammad-api-client-ruby'

  spec.files         = Dir['{lib}/**/*']
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'faraday', '~> 0.9'

  spec.add_development_dependency 'bundler', '~> 1.12'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'webmock'
end
