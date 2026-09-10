# frozen_string_literal: true

module ZammadAPI
  # Read access to a Zammad record's attributes.
  #
  # Zammad objects can carry administrator-defined custom attributes, so the
  # set of readable attributes is not known ahead of time and is resolved
  # through +method_missing+. Use {#fetch} when a missing attribute should be
  # an error rather than +nil+.
  module AttributeAccess
    # Suffixes that mark a method call as a predicate or bang method rather
    # than an attribute, so that typos like +save!+ still raise NoMethodError.
    NON_ATTRIBUTE_SUFFIXES = %w[! ?].freeze

    # All known attributes, deeply frozen.
    #
    # Writing through this hash would change what the record reports without
    # staging a change, so the next +save+ would not send it. {#to_h} returns a
    # copy that is safe to modify; an attribute writer is the way to stage one.
    #
    # @return [Hash{Symbol => Object}]
    attr_reader :attributes

    # @param key [Symbol, String]
    # @return [Object, nil]
    def [](key) = attributes[key.to_sym]

    # @param key [Symbol, String]
    # @param default [Object] returned instead of raising
    # @yieldparam key [Symbol] called instead of raising
    # @return [Object]
    # @raise [KeyError] when the attribute is absent and no fallback was given
    def fetch(key, *default)
      symbol = key.to_sym
      # An explicit &block argument cannot be resolved against Hash#fetch's
      # overloads by the type checker, so the block is forwarded with yield.
      # rubocop:disable-next Style/ExplicitBlockArgument
      return attributes.fetch(symbol) { |missing| yield(missing) } if block_given?
      return attributes.fetch(symbol, default.first) if !default.empty?

      attributes.fetch(symbol)
    end

    # @return [Boolean]
    def key?(key) = attributes.key?(key.to_sym)

    # @return [Hash{Symbol => Object}] a deep copy of all attributes, safe to
    #   modify
    def to_h = deep_dup(attributes)

    # @return [Integer, nil]
    def id = attributes[:id]

    # Enables Ruby pattern matching against a record's attributes.
    #
    # @example
    #   case client.ticket.find(1)
    #   in {state: 'closed'}
    #     nil
    #   in {state: String => state, priority: '3 high'}
    #     escalate(state)
    #   end
    #
    # @param keys [Array<Symbol>, nil] the keys the pattern asks for
    # @return [Hash{Symbol => Object}]
    def deconstruct_keys(keys) = keys.nil? ? attributes : attributes.slice(*keys)

    def method_missing(name, *args)
      identifier = name.to_s
      return super if NON_ATTRIBUTE_SUFFIXES.any? { identifier.end_with?(it) }
      return write_attribute(identifier.delete_suffix('=').to_sym, args.first) if identifier.end_with?('=')

      attributes[name]
    end

    def respond_to_missing?(name, include_private = false)
      identifier = name.to_s
      return false if NON_ATTRIBUTE_SUFFIXES.any? { identifier.end_with?(it) }
      return true if identifier.end_with?('=')

      attributes.key?(name) || super
    end

    private

    # Overridden by writable records; read-only ones fall back to NoMethodError.
    def write_attribute(key, _value)
      raise NoMethodError, "#{self.class.name} attributes are read-only (tried to set #{key})"
    end

    # Recursively converts string keys to symbols, including inside arrays, so
    # that user supplied attributes behave the same as decoded responses, and
    # freezes the result.
    #
    # The freezing is what makes {#attributes} safe to expose: a record that
    # handed out a writable hash would report changes it never staged and so
    # never sent. Strings are copied before being frozen, so freezing a value
    # the caller passed in does not reach back into their own variable.
    def frozen_attributes(value)
      case value
      when Hash   then value.to_h { |key, nested| [key.respond_to?(:to_sym) ? key.to_sym : key, frozen_attributes(nested)] }.freeze
      when Array  then value.map { frozen_attributes(it) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    # The inverse of {#frozen_attributes}, for handing out a copy that callers
    # may treat as their own.
    def deep_dup(value)
      case value
      when Hash   then value.to_h { |key, nested| [key, deep_dup(nested)] }
      when Array  then value.map { deep_dup(it) }
      when String then value.dup
      else value
      end
    end
  end
end
