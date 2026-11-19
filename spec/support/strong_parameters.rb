# frozen_string_literal: true

# What `ActionController::Parameters` is to this gem, without Rails: not a
# Hash, converting to one with String keys where it was permitted and
# refusing where it was not, and printing everything it holds.
#
# The real one answers `to_hash` with plain Hashes all the way down, so this
# one converts what it holds of its own kind.
class StrongParameters
  class Unfiltered < ArgumentError; end

  # @param values [Hash] the parameters, which may also be written as
  #   keywords: `StrongParameters.new(name: 'Support')`
  def initialize(values = {}, permitted: true, **keywords)
    @values    = values.merge(keywords)
    @permitted = permitted
  end

  def to_hash
    raise Unfiltered, 'unable to convert unpermitted parameters to hash' if !@permitted

    @values.to_h { |key, value| [key.to_s, value.is_a?(self.class) ? value.to_hash : value] }
  end

  def to_s = @values.to_s

  def inspect = "#<#{self.class.name} #{@values.inspect} permitted: #{@permitted}>"
end
