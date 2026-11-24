# frozen_string_literal: true

target :lib do
  signature 'sig'
  check 'lib'

  # socket is here for SocketError and openssl for OpenSSL::SSL::SSLError,
  # both of which Transport maps to ConnectionError; forwardable is here for
  # the collection shorthands ResourceProxy delegates to Collection; uri is
  # here for the parse Config makes of the instance url and the escaping of
  # record ids. None of the four is named in the signatures the gem
  # publishes - see SSL_ERRORS in sig/zammad_api/transport.rbs and
  # sig/vendor/internal.rbs - so this does not add anything a consumer has
  # to load.
  library 'json', 'logger', 'timeout', 'socket', 'openssl', 'forwardable', 'uri'

  configure_code_diagnostics do |hash|
    # Default keyword-argument hashes such as `attributes = {}` cannot be
    # annotated without hurting readability.
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = nil
  end
end

# A file written the way a typed project that uses this gem writes one, checked
# against the same signatures as lib/. It is never run - see spec/typed/usage.rb
# for what it pins.
#
# sig/vendor is in here, although a consumer does not have it, because Steep
# hands a signature file to every target of a project whatever the target's
# own pattern says. Listing only the published directories left this target
# with sig/vendor/internal.rbs all the same and without the library it names,
# so its signatures failed to load and Steep then skips the source files of
# such a target without a word: the check passed having checked nothing. That
# the published signatures stand on their own is what `rake rbs_published`
# establishes.
target :usage do
  signature 'sig', 'spec/typed/sig'
  check 'spec/typed'

  # logger is the one library the published signatures name; forwardable is
  # here for sig/vendor/internal.rbs.
  library 'logger', 'forwardable'
end
