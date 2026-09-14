# frozen_string_literal: true

target :lib do
  signature 'sig'
  check 'lib'

  # socket is here for SocketError, which Transport maps to ConnectionError.
  library 'json', 'logger', 'timeout', 'socket'

  configure_code_diagnostics do |hash|
    # Default keyword-argument hashes such as `attributes = {}` cannot be
    # annotated without hurting readability.
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = nil
  end
end
