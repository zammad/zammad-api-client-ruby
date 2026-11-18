# frozen_string_literal: true

require 'faraday'

module ZammadAPI
  # Writes a query the way Rails reads it back into the structure it was.
  #
  # Faraday's own encoder did this, and does it for everything but a list of
  # Hashes that do not all carry the same keys. A query string has no mark for
  # where one element of a list ends: a list of Hashes goes out as
  # `list[][key]=value` pairs, and Rack - and the parser Rails 8.1 has of its
  # own, which follows it - starts a new element only when a pair names a key
  # the element it is filling already has. Faraday writes the keys of every
  # Hash in alphabetical order, so the first pair of an element named
  # whichever of its keys sorts first, whether or not the element before had
  # it.
  #
  # Zammad's expert conditions are such a list. A group of conditions nests
  # them, and a group and a condition share `operator` and nothing else:
  #
  #   conditions: [
  #     {name: 'ticket.state_id', operator: 'is', value: [2]},
  #     {operator: 'AND', conditions: [a, b]}
  #   ]
  #
  # The second element went out `conditions` first, which the first element
  # does not have, so Rails read that into the first element and began the
  # second at `operator`: one condition holding the whole group, followed by
  # a group holding nothing. Zammad was handed a selector nobody wrote. It
  # answered this one with a 500, and the same two elements the other way
  # round with every ticket there is, as if no condition had been given.
  #
  # So an element that follows another Hash is written with a value the two
  # both have a place for first - see {.lead_path} - and the rest in the
  # order they always were. Where there is no such value no order works, and
  # {Transport.stringify_query} refuses the query before it gets here.
  #
  # The escaping is still Faraday's: this hands it the pairs in order, which
  # its encoder keeps for a list where it sorts a Hash.
  #
  # @api private
  module QueryEncoder
    module_function

    # @param params [Hash, nil] a query as {Transport.stringify_query} leaves
    #   it
    # @return [String, nil] the query string, nil for no query
    def encode(params)
      return nil if params.nil?

      Faraday::NestedParamsEncoder.encode(hash_pairs(nil, params.to_hash, nil))
    end

    # Reading a query string back is not this module's business, and Faraday
    # asks whatever encodes for it: a query written into the instance URL is
    # decoded on the way in.
    #
    # @param query [String, nil]
    # @return [Hash, nil]
    def decode(query) = Faraday::NestedParamsEncoder.decode(query)

    # The value to write first for a Hash that follows another in a list, so
    # that Rails begins a new element with it: one the element before has a
    # place for as well, named by the keys that lead to it.
    #
    # A plain value, reached through Hashes alone. The pair that writes it
    # names every key on the way down, and Rails begins a new element where
    # the element it is filling has all of them already. A value inside a
    # list never begins one, whatever the element before holds.
    #
    # @param element [Hash]
    # @param previous [Object] the element before it
    # @return [Array, nil] the keys leading to the value, outermost first.
    #   nil where no value will do, and where none is needed: the element is
    #   the first, or follows something that is not a Hash, and begins a new
    #   one whatever is written first
    def lead_path(element, previous)
      return nil if !previous.is_a?(Hash)

      sorted_keys(element).each do |key|
        # Taken in the element before only where something was written for
        # it there. A Hash with no value in it is not written, so the key is
        # missing from what Rails read, and a pair naming it is read into
        # that element rather than beginning the next.
        next if !previous.key?(key) || !written?(previous[key])

        value = element[key]
        next if value.is_a?(Array)
        return [key] if !value.is_a?(Hash)

        inner = lead_path(value, previous[key])
        return [key, *inner] if inner
      end

      nil
    end

    # Why Rails could not read an element of a list back as it was written,
    # where it could not.
    #
    # +:merged+ is a Hash it would read into the Hash before it, there being
    # no value to begin a new element with. +:empty+ is a Hash nothing is
    # written for, which leaves the list one element short. +:list+ is a
    # list directly inside a list: both are written `[]`, and each value of
    # the inner one is read as a list of its own.
    #
    # @param element [Object]
    # @param previous [Object] the element before it, nil for the first
    # @return [Symbol, nil] nil for an element that is read back as it was
    def misread(element, previous)
      return :list  if element.is_a?(Array)
      return nil    if !element.is_a?(Hash)
      return :empty if !written?(element)

      :merged if previous.is_a?(Hash) && lead_path(element, previous).nil?
    end

    # Whether anything is written for a value. Nothing is for a Hash with
    # nothing in it, or with nothing but such Hashes in it, so as an element
    # of a list it is not there for Rails to read.
    #
    # @return [Boolean]
    def written?(value) = !value.is_a?(Hash) || value.each_value.any? { written?(it) }

    # @param lead [Array, nil] the keys leading to the value to write first
    # @return [Array<Array(String, String)>] one pair per value, in the order
    #   they are written
    def hash_pairs(prefix, hash, lead)
      keys = sorted_keys(hash)
      keys = [lead.first, *(keys - [lead.first])] if lead

      keys.flat_map do |key|
        # The rest of the way to the value, for the key that leads to it.
        inner = lead && key == lead.first && lead.size > 1 ? lead.drop(1) : nil

        value_pairs(prefix ? "#{prefix}[#{key}]" : key.to_s, hash[key], inner)
      end
    end

    def value_pairs(path, value, lead = nil)
      case value
      when Hash  then hash_pairs(path, value, lead)
      when Array then array_pairs("#{path}[]", value)
      else [[path, value]]
      end
    end

    def array_pairs(path, array)
      # A list with nothing in it is written as its name alone, which is what
      # Faraday wrote for one.
      return [[path, nil]] if array.empty?

      array.each_with_index.flat_map do |element, index|
        next value_pairs(path, element) if !element.is_a?(Hash)

        hash_pairs(path, element, index.zero? ? nil : lead_path(element, array[index - 1]))
      end
    end

    def sorted_keys(hash) = hash.keys.sort_by(&:to_s)
  end
end
