# frozen_string_literal: true

target :lib do
  signature 'sig'
  check 'lib'

  # socket is here for SocketError and openssl for OpenSSL::SSL::SSLError,
  # both of which Transport maps to ConnectionError. Neither is named in the
  # signatures the gem publishes - see SSL_ERRORS in sig/zammad_api/transport.rbs
  # - so this does not add anything a consumer has to load.
  library 'json', 'logger', 'timeout', 'socket', 'openssl'

  configure_code_diagnostics do |hash|
    # Default keyword-argument hashes such as `attributes = {}` cannot be
    # annotated without hurting readability.
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = nil
  end
end
