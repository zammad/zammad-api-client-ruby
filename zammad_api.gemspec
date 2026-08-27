# frozen_string_literal: true

require_relative 'lib/zammad_api/version'

Gem::Specification.new do |spec|
  spec.name     = 'zammad_api'
  spec.version  = ZammadAPI::VERSION
  spec.authors  = ['Martin Edenhofer', 'Martin Gruner', 'Mantas Masalskis']
  spec.email    = ['support@zammad.org']

  spec.summary     = 'Zammad API v1.0 client.'
  spec.description = 'Ruby wrapper for the Zammad API v1.0.'
  spec.homepage    = 'https://github.com/zammad/zammad-api-client-ruby'
  spec.licenses    = ['AGPL-3.0-only', 'MIT']

  # Keep in sync with TargetRubyVersion in .rubocop.yml and the CI matrix.
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['allowed_push_host']      = 'https://rubygems.org'
  spec.metadata['homepage_uri']           = spec.homepage
  spec.metadata['source_code_uri']        = spec.homepage
  spec.metadata['changelog_uri']          = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['bug_tracker_uri']        = "#{spec.homepage}/issues"
  spec.metadata['documentation_uri']      = "https://rubydoc.info/gems/zammad_api/#{ZammadAPI::VERSION}"
  spec.metadata['rubygems_mfa_required']  = 'true'

  # sig/vendor holds stand-in signatures for dependencies that ship none; they
  # are for this repository's own type checking and must not be published.
  spec.files = Dir['lib/**/*.rb', 'sig/**/*.rbs'].grep_v(%r{\Asig/vendor/}) + %w[
    CHANGELOG.md
    LICENSE.AGPL.txt
    LICENSE.MIT.txt
    LICENSE.md
    README.md
  ]
  spec.require_paths      = ['lib']
  spec.extra_rdoc_files   = ['README.md', 'CHANGELOG.md']

  spec.add_dependency 'faraday', '~> 2.9'
  spec.add_dependency 'faraday-retry', '~> 2.2'
end
