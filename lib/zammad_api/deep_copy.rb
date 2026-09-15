# frozen_string_literal: true

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
