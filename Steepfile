# frozen_string_literal: true

target :lib do
  signature 'sig'
  check 'lib'

  # uri is here for the parse Config makes of the instance url and the
  # escaping of record ids. The signatures the gem publishes do not name it,
  # so this does not add anything a consumer has to load.
  library 'json', 'logger', 'timeout', 'uri'

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
# own pattern says. That the published signatures stand on their own is what
# `rake rbs_published` establishes.
target :usage do
  signature 'sig', 'spec/typed/sig'
  check 'spec/typed'

  # logger is the one library the published signatures name.
  library 'logger'
end
