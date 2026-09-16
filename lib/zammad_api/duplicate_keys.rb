# frozen_string_literal: true

module ZammadAPI
  # One rule for two keys that name the same parameter.
  #
  # Both places that normalise caller-supplied parameter names had to refuse a
  # collision, because normalising is what creates one: {Collection#where} maps
  # every key to a Symbol and {Transport.stringify_query} maps every key to a
  # String, so `sort_by` and `'sort_by'` become one key and the value that
  # arrived first is dropped without a word. Written twice, the two refusals
  # had already drifted into two different sentences for the same mistake.
  #
  # @api private
  module DuplicateKeys
    module_function

    # Maps every key through the block, refusing two that land on one name.
    #
    # The key each name was first seen as is kept, so the message can print
    # both spellings: naming only the second left the reader to guess the
    # first, which in a parameter hash assembled across several merges is the
    # whole of the debugging.
    #
    # @param hash [Hash]
    # @param prefix [String, nil] the parameter path this Hash sits at, for a
    #   nested structure
    # @param noun [String] what the caller calls one of these, for the message
    # @yieldparam key [Object] a key to normalise
    # @return [Hash] the hash with normalised keys and untouched values
    # @raise [ArgumentError] for two keys that name the same thing
    def normalize(hash, prefix: nil, noun: 'parameter')
      seen = {}

      hash.each_with_object({}) do |(key, value), result|
        name = yield(key)
        raise ArgumentError, message(noun, prefix ? "#{prefix}[#{name}]" : name, seen[name], key) if seen.key?(name)

        seen[name]   = key
        result[name] = value
      end
    end

    # @api private
    def message(noun, path, first, second)
      "#{noun} #{path} was given twice, as #{first.inspect} and as #{second.inspect}: " \
        'pass it once, so that which value reaches the endpoint does not depend on Hash order'
    end
  end
end
