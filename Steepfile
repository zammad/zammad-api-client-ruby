# frozen_string_literal: true

target :lib do
  signature 'sig'
  check 'lib'

  # socket is here for SocketError and openssl for OpenSSL::SSL::SSLError,
  # both of which Transport maps to ConnectionError; forwardable is here for
  # the collection shorthands ResourceProxy delegates to Collection. None of
  # the three is named in the signatures the gem publishes - see SSL_ERRORS in
  # sig/zammad_api/transport.rbs and sig/vendor/internal.rbs - so this does not
  # add anything a consumer has to load.
  library 'json', 'logger', 'timeout', 'socket', 'openssl', 'forwardable'

  configure_code_diagnostics do |hash|
    # Default keyword-argument hashes such as `attributes = {}` cannot be
    # annotated without hurting readability.
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = nil
  end
end
