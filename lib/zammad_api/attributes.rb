# frozen_string_literal: true

module ZammadAPI
  # The Hash a record hands its attributes out in.
  #
  # A Hash in every way but how it is printed, which is with the value under
  # every key that names a credential blanked, the way
  # {Resources::Base#inspect} prints a record.
  #
  # It is frozen where it is handed out, and Ruby quotes a frozen object in
  # the error for a write to it. `user.attributes[:vip] = true`, which is how
  # 1.x staged a change, raised `FrozenError: can't modify frozen Hash:
  # {login: "jane", password: "hunter2"}`, and the message of an error is
  # what a log and an error tracker keep. The record printed its attributes
  # blanked, and the Hash it handed out printed itself.
  #
  # Only the printing. Every value reads as it is, and +to_h+, +to_json+ and
  # YAML write them out, because handing them over is what a record is for.
  # {#to_h} is a plain Hash at every depth. One made by +slice+ or +select+
  # is plain itself and holds the Hashes inside it as they are, which are of
  # this class.
  #
  # One thing does ask for the class: a JSON encoder that takes nothing but
  # the core types, `JSON.generate(value, strict: true)` and a `JSON::Coder`
  # without a block, refuses a subclass of Hash by its name. {#to_h} is what
  # to hand it.
  #
  # What it holds is not covered where that is not a Hash. A String cannot
  # be told how to print, so `user.attributes[:password] << 'x'` still
  # quotes the password it was asked to change, and an Array prints what is
  # in it.
  #
  # @example
  #   user.attributes[:vip] = true
  #   # FrozenError: can't modify frozen ZammadAPI::Attributes: {login: "jane", password: "[REDACTED]"}
  class Attributes < Hash
    # @return [String] the Hash as Ruby prints one, credentials blanked
    def inspect = Transport.redact(self).inspect

    # +Hash#to_s+ is +Hash#inspect+ under a second name, and stays the one
    # Hash defines unless it is named again here.
    alias to_s inspect

    # A plain Hash of plain Hashes, the caller's own to modify.
    #
    # +Hash#to_h+ answers with a plain Hash that holds what this one holds,
    # and every Hash inside the attributes of a record is of this class too.
    # So `user.attributes.to_h` was plain as far as its first nested Hash,
    # and a strict JSON encoder refused it there as it refuses the
    # attributes themselves: "ZammadAPI::Attributes not allowed in JSON",
    # for what 1.x handed out as Hashes. What {Resources::Base#to_h} answers
    # for the whole record, this answers for any part of it:
    # `user.preferences.to_h`.
    #
    # With a block it is +Hash#to_h+, which builds a plain Hash from the
    # pairs the block answers.
    #
    # The steep:ignore is for the two shapes of the method in one body: the
    # checker holds each branch to both of them.
    #
    # @return [Hash] a writable deep copy
    def to_h(&block) = block ? super : DeepCopy.writable_copy(self) # steep:ignore MethodBodyTypeMismatch

    # What +pp+ prints, which is not what {#inspect} answers for a Hash.
    #
    # @param printer [PP]
    # @return [void]
    def pretty_print(printer) = printer.pp(Transport.redact(self))

    # Written to YAML as the plain mapping a Hash is.
    #
    # Psych tags a subclass of Hash with its class, and refuses to load a
    # tag it was not told to expect, so `record.attributes.to_yaml` would
    # have stopped loading with +YAML.load+.
    #
    # @param coder [Psych::Coder]
    # @return [void]
    def encode_with(coder) = coder.represent_map(nil, self)
  end
end
