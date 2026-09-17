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
  #
  # This also carries the object protocols a record is expected to answer:
  # {#==} and {#hash} identify a record by its id, {#deconstruct_keys} makes
  # one matchable with +case/in+, and {#to_json} serializes its attributes.
  module AttributeAccess
    # Suffixes that mark a method call as a predicate or bang method rather
    # than an attribute, so that typos like +save!+ still raise NoMethodError.
    NON_ATTRIBUTE_SUFFIXES = %w[! ?].freeze

    # What a writer for an attribute is named: a plain identifier and an `=`.
    #
    # Ending in `=` is not enough, because Ruby's operators do too. `record[:x]
    # = 1` reaches `method_missing` as `:[]=` and used to stage an attribute
    # literally called `[]` whose value was the index - the write was lost, no
    # error was raised, and the next `save` sent `{"[]": "x"}` to Zammad.
    # `record <= 5` did the same for an attribute called `<`.
    ATTRIBUTE_WRITER = /\A[a-zA-Z_]\w*=\z/
    private_constant :ATTRIBUTE_WRITER

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

    # Stages an attribute by name, the writer matching {#[]}.
    #
    # Defined rather than left to `method_missing`, which saw `:[]=` as a
    # writer for an attribute called `[]` and staged the index as its value.
    # A read-only record refuses this the way it refuses any other write, and
    # {#respond_to?} says so before it is called.
    #
    # @param key [Symbol, String]
    # @param value [Object]
    # @return [Object] the staged value
    # @raise [Error] when the attribute cannot be staged, such as +id+
    # @raise [NoMethodError] when the record is read-only
    def []=(key, value)
      write_attribute(key.to_sym, value)
    end

    # @param key [Symbol, String]
    # @param default [Object] returned instead of raising
    # @yieldparam key [Symbol] called instead of raising
    # @return [Object]
    # @raise [ArgumentError] when more than one fallback was given
    # @raise [KeyError] when the attribute is absent and no fallback was given
    def fetch(key, *default)
      # Hash#fetch refuses a third argument, and so does this: collecting the
      # fallback with a splat and reading `default.first` accepted
      # `fetch(:a, :b, :c)` - a multi-key read that this has never been - and
      # answered it with `:b`. A method whose whole point is that a missing
      # attribute is an error has no business swallowing a mistyped call.
      raise ArgumentError, "wrong number of arguments (given #{default.size + 1}, expected 1..2)" if default.size > 1

      # Hash#fetch warns for this and then ignores the default, so this does
      # too rather than silently picking one of the two fallbacks a caller
      # cannot have meant to pass together.
      #
      # `uplevel` so that this reads like the warning it mirrors: Hash#fetch
      # names the line that made the call, and a bare Kernel#warn named
      # nothing at all - neither the call site nor the library it came from,
      # which in an application with several such calls is everything the
      # reader needs. Kernel#warn writes the `warning: ` prefix itself when
      # given `uplevel`, so the message must not carry its own.
      #
      # Nothing here has to consult $VERBOSE. Kernel#warn is already silent
      # when warnings are off, so `ruby -W0` and `$VERBOSE = nil` quiet this
      # the same way they quiet Hash#fetch's own warning.
      warn('block supersedes default value argument', uplevel: 1) if block_given? && !default.empty?

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

    # Whether +other+ is the same Zammad record: the same class, carrying the
    # same id.
    #
    # A record with no id is equal only to itself, because two unsaved records
    # are two records waiting to be created however alike their attributes
    # are. That also means the first save of a record changes its {#hash}, so
    # one used as a Hash key before being saved has to be rehashed after.
    #
    # @example
    #   client.ticket.find(1) == client.ticket.find(1)             # => true
    #   [client.ticket.find(1), client.ticket.find(1)].uniq.size   # => 1
    #
    # @param other [Object]
    # @return [Boolean]
    def ==(other)
      return true  if equal?(other)
      return false if !other.instance_of?(self.class)

      !id.nil? && other.id == id
    end
    alias eql? ==

    # Consistent with {#==}, so that records can be deduplicated with +uniq+,
    # collected in a +Set+ and used as Hash keys.
    #
    # The class is part of the digest because an id is only unique within one
    # kind of record: ticket 1 and user 1 are different records.
    #
    # @return [Integer]
    def hash
      id.nil? ? super : [self.class, id].hash
    end

    # The attributes, for a JSON encoder.
    #
    # Named the way ActiveSupport and its encoders expect, so that a record
    # nested inside a structure being serialized renders as its attributes.
    #
    # @return [Hash{Symbol => Object}]
    def as_json(*) = to_h

    # Without this, a record would serialize as its +to_s+, because that is
    # what +Object#to_json+ falls back to.
    #
    # @example
    #   client.group.find(1).to_json # => "{\"id\":1,\"name\":\"Support\"}"
    #
    # @param state [JSON::State, nil] passed by +JSON.generate+ when a record
    #   is nested in a structure it is serializing
    # @return [String] the attributes as a JSON object
    def to_json(state = nil) = to_h.to_json(state)

    def method_missing(name, *args)
      identifier = name.to_s
      return super if NON_ATTRIBUTE_SUFFIXES.any? { identifier.end_with?(it) }
      return write_attribute(identifier.delete_suffix('=').to_sym, args.first) if ATTRIBUTE_WRITER.match?(identifier)
      return attributes[name] if attributes.key?(name)

      # An attribute the record does not carry used to read as nil, which made
      # `ticket.titel` a silent nil that flowed on into whatever was written
      # with it - and left this module the one place in the gem that answers a
      # question it cannot answer instead of saying so. It also put
      # `respond_to?` and the call itself at odds: `respond_to?(:titel)` was
      # false and `method(:titel)` raised NameError while `ticket.titel`
      # worked, so generic code that asks before it calls - a serializer, a
      # delegator, `try` - was told the reader did not exist.
      #
      # Built rather than left to `super`, so that the message can name what
      # to reach for instead, while `name` and `receiver` stay what a bare
      # NoMethodError would have carried.
      #
      # The steep:ignore is for `name`: NameError.new takes a Symbol there and
      # NoMethodError#name answers with one, while the core signature
      # describes the parameter as a String.
      raise NoMethodError.new(unknown_attribute_message(name), name, args, receiver: self) # steep:ignore ArgumentTypeMismatch
    end

    # `[]=` is a defined method, so `respond_to_missing?` never sees it and a
    # read-only record answered true for the one writer it has while answering
    # false for every named one - then raised NoMethodError when it was called.
    # That is the invariant the writer branch below is conditional for: generic
    # code asks before it writes, and a record that claims a writer it would
    # refuse leads it straight into the exception it was checking to avoid.
    #
    # Compared as a String, because `respond_to?` takes either spelling and
    # Ruby does not normalise the argument before it reaches here. Compared to
    # the Symbol alone, `respond_to?('[]=')` fell through to the definition
    # and answered true on a record that refuses every write - the same wrong
    # answer this method exists to prevent, reached by the other spelling.
    # rubocop:disable-next Style/OptionalBooleanParameter -- Ruby's own signature
    def respond_to?(name, include_private = false)
      return writable_attributes? if name.to_s == '[]='

      super
    end

    def respond_to_missing?(name, include_private = false)
      identifier = name.to_s
      return false if NON_ATTRIBUTE_SUFFIXES.any? { identifier.end_with?(it) }
      # Not an unconditional true: a read-only record that claimed a writer and
      # then raised NoMethodError when one was called would defeat the point of
      # asking, and lead generic code - serializers, form binders,
      # assign_attributes loops - straight into the exception it was checking
      # to avoid.
      return writable_attributes? && attribute_writable?(identifier.delete_suffix('=').to_sym) if ATTRIBUTE_WRITER.match?(identifier)

      attributes.key?(name) || super
    end

    private

    # Why an attribute is missing is worth saying, because the two reasons
    # lead somewhere quite different: a name that is simply wrong, and a
    # record Zammad served less of than it holds. The second is the same fact
    # {Resources::Base#no_id_message} and {Resources::Base#write_attribute}
    # are written around - Zammad reduces the object it serializes for a
    # client whose user may not see the whole record - and it is not
    # something the spelling of the call can show.
    def unknown_attribute_message(name)
      # Sorted by the name rather than by the key, because a key that could
      # not become a Symbol is left as it arrived - {DeepCopy.symbolize} says
      # so - and `[:name, 1].sort` raises, which would replace this message
      # with an ArgumentError from inside the method that explains it.
      carried = attributes.keys.sort_by(&:to_s).join(', ')

      "undefined attribute #{name} for #{self.class.name}. This record carries " \
        "#{attributes.empty? ? 'no attributes at all' : carried}. " \
        "Check the spelling, or read it with [#{name.inspect}] or fetch(#{name.inspect}, nil) where it may be absent. " \
        'Zammad also serves a reduced object where the authenticated user may not see the whole record, so an ' \
        'attribute the record has in Zammad can still be missing here - check what this client may read.'
    end

    # Whether this record stages attribute writes, so that {#respond_to?} and
    # calling a writer agree.
    def writable_attributes? = false

    # Whether one particular attribute may be written. Overridden by records
    # that refuse one: a record that claimed `id=` and then raised when it was
    # called would defeat the point of asking, which is the whole reason the
    # writer branch above is not an unconditional true.
    def attribute_writable?(_key) = true

    # Overridden by writable records; read-only ones fall back to NoMethodError.
    def write_attribute(key, _value)
      raise NoMethodError, "#{self.class.name} attributes are read-only (tried to set #{key})"
    end

    # Recursively converts string keys to symbols, including inside arrays, so
    # that user supplied attributes behave the same as decoded responses, and
    # freezes the result. See {DeepCopy} for why the walk lives there.
    def frozen_attributes(value) = DeepCopy.frozen_copy(value, symbolize_keys: true)

    # The inverse of {#frozen_attributes}, for handing out a copy that callers
    # may treat as their own.
    def deep_dup(value) = DeepCopy.writable_copy(value)
  end
end
