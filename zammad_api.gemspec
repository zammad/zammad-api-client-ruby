# frozen_string_literal: true

require_relative 'lib/zammad_api/version'

Gem::Specification.new do |spec|
  spec.name     = 'zammad_api'
  spec.version  = ZammadAPI::VERSION
  spec.authors  = ['Martin Edenhofer', 'Martin Gruner', 'Mantas Masalskis']
  spec.email    = ['support@zammad.org']

  # v1.0 is the version of the API, the one a Zammad serves under /api/v1, and
  # not of this gem.
  spec.summary     = 'Ruby client for the Zammad API v1.0.'
  spec.description = 'Tickets, articles, users, organizations and groups of a Zammad instance as records to ' \
                     'find, create, update and destroy, with collections that paginate themselves, timeouts, ' \
                     'retries and an error class per kind of failure.'
  spec.homepage    = 'https://github.com/zammad/zammad-api-client-ruby'
  spec.licenses    = ['AGPL-3.0-only', 'MIT']

  # Keep in sync with TargetRubyVersion in .rubocop.yml and the CI matrix.
  #
  # 3.4 rather than 3.3, which gets security fixes until March 2027, for the
  # `it` block parameter that lib/ uses throughout. Nothing else needs 3.4:
  # lowering the floor is rewriting `it` to `_1`, the five spec expectations
  # of the format Hash#inspect has had since 3.4, and a CI entry.
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['allowed_push_host']      = 'https://rubygems.org'
  spec.metadata['source_code_uri']        = spec.homepage
  spec.metadata['changelog_uri']          = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['bug_tracker_uri']        = "#{spec.homepage}/issues"
  spec.metadata['documentation_uri']      = "https://rubydoc.info/gems/zammad_api/#{ZammadAPI::VERSION}"
  spec.metadata['rubygems_mfa_required']  = 'true'

  # sig/vendor holds stand-ins for dependencies that ship no signatures. They
  # exist only for this repository's own type checking and are not published.
  spec.files = Dir['lib/**/*.rb', 'sig/**/*.rbs'].grep_v(%r{\Asig/vendor/}) + %w[
    .yardopts
    CHANGELOG.md
    LICENSE.AGPL.txt
    LICENSE.MIT.txt
    LICENSE.md
    README.md
    UPGRADING.md
  ]
  spec.require_paths      = ['lib']
  spec.extra_rdoc_files   = ['README.md', 'UPGRADING.md', 'CHANGELOG.md']

  spec.add_dependency 'faraday', '~> 2.9'
  spec.add_dependency 'faraday-retry', '~> 2.2'
  # Required by lib/zammad_api/config.rb. From Ruby 4.0 on it is a bundled
  # gem, which Bundler makes loadable only where the bundle names it, and
  # Faraday names it from 2.10.0 on: a bundle resolved to 2.9 had none.
  spec.add_dependency 'logger', '~> 1.5'
end
