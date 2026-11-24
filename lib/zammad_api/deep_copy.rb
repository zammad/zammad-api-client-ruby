# frozen_string_literal: true

module ZammadAPI
  # Recursive copies of the plain JSON structures this gem passes around.
  #
  # @api private
  module DeepCopy
    module_function

    # A frozen deep copy, so a record's attributes cannot change behind its
    # back. Strings are copied before they are frozen, so the caller's own
    # values are left alone.
    #
    # @param value [Object]
    # @param symbolize_keys [Boolean] whether Hash keys become Symbols, so
    #   that caller-supplied attributes behave the same as decoded responses
    # @return [Object] a frozen copy
    def frozen_copy(value, symbolize_keys: false)
      case value
      when Hash   then value.to_h { |key, nested| [symbolize_keys ? symbolize(key) : key, frozen_copy(nested, symbolize_keys: symbolize_keys)] }.freeze
      when Array  then value.map { frozen_copy(it, symbolize_keys: symbolize_keys) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    # A writable deep copy of a frozen structure.
    #
    # @param value [Object]
    # @return [Object]
    def writable_copy(value)
      case value
      when Hash   then value.to_h { |key, nested| [key, writable_copy(nested)] }
      when Array  then value.map { writable_copy(it) }
      when String then value.dup
      else value
      end
    end

    # @param key [Object]
    # @return [Object] the key as a Symbol, where it converts to one
    def symbolize(key) = key.respond_to?(:to_sym) ? key.to_sym : key
  end
end
