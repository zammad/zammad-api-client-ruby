# frozen_string_literal: true

target :lib do
  signature 'sig'
  check 'lib'

  library 'json', 'logger', 'timeout'

  configure_code_diagnostics do |hash|
    # Default keyword-argument hashes such as `attributes = {}` cannot be
    # annotated without hurting readability.
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = nil
  end
end
