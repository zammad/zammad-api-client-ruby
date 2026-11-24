# frozen_string_literal: true

require 'json'

require_relative 'deep_copy'

module ZammadAPI
  # Read access to a Zammad record's attributes.
  #
  # Zammad objects can carry administrator-defined custom attributes, so the
  # set of readable attributes is not known ahead of time and is resolved
  # through +method_missing+. A reader for an attribute the record does not
  # carry raises +NoMethodError+; {#[]}, {#fetch} with a default, and {#key?}
  # are the readers for an attribute that may be absent.
  module AttributeAccess
    # What a writer for an attribute is named: a plain identifier and an `=`,
    # so that operators such as +<=+ are not taken for one.
    ATTRIBUTE_WRITER = /\A[a-zA-Z_]\w*=\z/
    private_constant :ATTRIBUTE_WRITER

    # All known attributes, deeply frozen. {#to_h} returns a copy that is safe
    # to modify; an attribute writer is the way to stage a change.
    #
    # @return [Hash{Symbol => Object}]
    attr_reader :attributes

    # @param key [Symbol, String]
    # @return [Object, nil]
    def [](key) = attributes[key.to_sym]

    # Stages a change to an attribute, like the attribute writer does.
    #
    # @param key [Symbol, String]
    # @param value [Object]
    # @return [Object] the staged value
    def []=(key, value)
      write_attribute(key.to_sym, value)
    end

    # Reads an attribute the way +Hash#fetch+ does.
    #
    # @param key [Symbol, String]
    # @return [Object]
    # @raise [KeyError] when the record does not carry the attribute and
    #   neither a default nor a block is given
    def fetch(key, *default, &block) = attributes.fetch(key.to_sym, *default, &block) # steep:ignore UnresolvedOverloading

    # @return [Boolean]
    def key?(key) = attributes.key?(key.to_sym)

    # @return [Hash{Symbol => Object}] a deep copy of all attributes, safe to
    #   modify
    def to_h = DeepCopy.writable_copy(attributes)

    # @return [Integer, nil]
    def id = attributes[:id]

    # Enables Ruby pattern matching against a record's attributes.
    #
    # @example
    #   case client.tickets.find(1)
    #   in {state: 'closed'}
    #     nil
    #   in {state: String => state, priority: '3 high'}
    #     escalate(state)
    #   end
    #
    # @param keys [Array<Symbol>, nil] the keys the pattern asks for
    # @return [Hash{Symbol => Object}]
    def deconstruct_keys(keys) = keys.nil? ? attributes : attributes.slice(*keys)

    # Whether +other+ is the same Zammad record: the same class, carrying the
    # same id, read from the same Zammad. A record with no id is equal only
    # to itself.
    #
    # @param other [Object]
    # @return [Boolean]
    def ==(other)
      return true  if equal?(other)
      return false if !other.instance_of?(self.class)

      # The steep:ignore is for `installation`, which is protected: RBS has
      # no word for that, so the signature declares it private.
      !id.nil? && other.id == id && other.installation == installation # steep:ignore NoMethod
    end
    alias eql? ==

    # Consistent with {#==}, so that records can be deduplicated with +uniq+,
    # collected in a +Set+ and used as Hash keys.
    #
    # @return [Integer]
    def hash
      id.nil? ? super : [self.class, installation, id].hash
    end

    # @return [Hash{Symbol => Object}] the attributes, for a JSON encoder
    def as_json(*) = to_h

    # @return [String] the attributes as a JSON object
    def to_json(*args) = to_h.to_json(*args) # steep:ignore UnexpectedPositionalArgument

    def method_missing(name, *args)
      identifier = name.to_s
      return write_attribute(identifier.delete_suffix('=').to_sym, args.first) if ATTRIBUTE_WRITER.match?(identifier) && args.size == 1
      return attributes[name] if args.empty? && attributes.key?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      identifier = name.to_s
      return writable_attributes? if ATTRIBUTE_WRITER.match?(identifier)

      attributes.key?(name) || super
    end

    protected

    # The Zammad the record was read from, for {#==}: an id is only unique
    # within one installation.
    #
    # @return [String, nil]
    def installation = nil

    private

    def writable_attributes? = false

    def write_attribute(key, _value)
      raise NoMethodError, "#{self.class.name} attributes are read-only (tried to set #{key})"
    end

    def frozen_attributes(value) = DeepCopy.frozen_copy(value, symbolize_keys: true)
  end
end
