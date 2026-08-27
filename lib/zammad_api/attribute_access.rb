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

    # @return [Hash{Symbol => Object}] all known attributes
    attr_reader :attributes

    # @param key [Symbol, String]
    # @return [Object, nil]
    def [](key)
      attributes[key.to_sym]
    end

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
    def key?(key)
      attributes.key?(key.to_sym)
    end

    # @return [Hash{Symbol => Object}] a copy of all attributes
    def to_h
      attributes.dup
    end

    # @return [Integer, nil]
    def id
      attributes[:id]
    end

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
    # that user supplied attributes behave the same as decoded responses.
    def deep_symbolize(value)
      case value
      when Hash  then value.to_h { |key, nested| [key.respond_to?(:to_sym) ? key.to_sym : key, deep_symbolize(nested)] }
      when Array then value.map { deep_symbolize(it) }
      else value
      end
    end
  end
end
