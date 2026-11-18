# frozen_string_literal: true

require_relative 'duplicate_keys'

module ZammadAPI
  # Recursive copies of the plain JSON structures this gem passes around.
  #
  # Three places need the same walk - a record freezing the attributes it was
  # built with, a record handing a copy of them back, and the test kit
  # recording the payload a request carried - and each used to carry its own.
  # A rule written three times is one that gets fixed in one of them: the
  # test kit's copy already differed by not symbolizing keys, and nothing
  # said whether that was the point or an oversight.
  #
  # Only Hash, Array and String are walked, because that is the whole of what
  # +JSON.parse+ builds and what a caller may hand in as attributes. Numbers,
  # booleans and nil are immutable already and are passed through untouched.
  #
  # One walk, deliberately. A record built from a response copies every String
  # of a body +JSON.parse+ has just built and nothing else holds, so a variant
  # that froze such a body in place would save that copy on the paging hot
  # path - which is a real cost, and still not a reason for a second walk:
  # three of them is what this module replaced, and the one that differed did
  # so without anything to say whether the difference was the point. If the
  # copy is worth removing, it is an argument to this walk and it applies to
  # the one place that can prove nothing else references the value.
  #
  # @api private
  module DeepCopy
    module_function

    # A frozen deep copy.
    #
    # Named for what it returns rather than `freeze`/`dup`, which would shadow
    # the Object methods of those names inside this module and read as them at
    # every call site.
    #
    # Freezing is what makes a record's attribute hash safe to hand out: one
    # that gave away a writable hash would report changes it never staged and
    # so never sent. Strings are copied before being frozen, so freezing a
    # value the caller passed in does not reach back into their own variable.
    #
    # Keys are left alone. Ruby copies and freezes an unfrozen String key on
    # insertion, so a Hash built here never holds the caller's own String, and
    # symbolizing produces an immutable key anyway - which leaves only an
    # Array or a custom object as a key that this walk would change. `JSON`
    # cannot build one, so it could only come from a caller's own attribute
    # hash, and paying a call per key on the record-building path for it is
    # the cost this module's own note above weighs and declines.
    #
    # @param value [Object]
    # @param symbolize_keys [Boolean] whether Hash keys become Symbols, so
    #   that caller-supplied attributes behave the same as decoded responses
    # @return [Object] a frozen copy
    # @raise [ArgumentError] when symbolizing lands two keys of one Hash on
    #   one name
    def frozen_copy(value, symbolize_keys: false)
      case value
      when Hash   then frozen_hash(value, symbolize_keys)
      when Array  then value.map { frozen_copy(it, symbolize_keys: symbolize_keys) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    # The Hash branch of {frozen_copy}.
    #
    # Two keys that symbolize to one name are refused rather than merged.
    # Symbolizing is what creates the collision, the way stringifying does
    # for a query - see {DuplicateKeys} - and here it went unrefused:
    # `client.groups.new('name' => 'Support', name: 'Sales')` built a record
    # holding `name: 'Sales'` alone, and an attribute Hash put together from
    # form parameters and defaults lost a value to Hash order without a word.
    # {Resources::Ticket#add_article} had to take both spellings of
    # `ticket_id` out by hand for it.
    #
    # Asked of the sizes, so that a Hash with no collision in it - every one
    # built from a response - pays one comparison and no call per key. The
    # walk that names the two spellings is made only once there is a pair to
    # name.
    #
    # @api private
    # @return [Hash] a frozen copy
    # @raise [ArgumentError]
    def frozen_hash(hash, symbolize_keys)
      copy = hash.to_h { |key, nested| [symbolize_keys ? symbolize(key) : key, frozen_copy(nested, symbolize_keys: symbolize_keys)] }
      DuplicateKeys.normalize(hash, noun: 'attribute') { symbolize(it) } if symbolize_keys && copy.size != hash.size

      copy.freeze
    end

    # A writable deep copy, for handing out something callers may treat as
    # their own. The inverse of {frozen_copy}.
    #
    # @param value [Object]
    # @return [Object] an unfrozen copy
    def writable_copy(value)
      case value
      when Hash   then value.to_h { |key, nested| [key, writable_copy(nested)] }
      when Array  then value.map { writable_copy(it) }
      when String then value.dup
      else value
      end
    end

    # A key that cannot become a Symbol is left as it is rather than refused:
    # it came from a caller's attribute hash, and a record is not the place
    # to decide that Zammad will not accept it.
    #
    # @api private
    def symbolize(key) = key.respond_to?(:to_sym) ? key.to_sym : key
  end
end
