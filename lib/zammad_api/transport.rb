# frozen_string_literal: true

require 'date'
require 'faraday'
require 'faraday/retry'
require 'json'
require 'openssl'
require 'socket'
require 'timeout'

require_relative 'duplicate_keys'
require_relative 'errors'
require_relative 'query_encoder'
require_relative 'response'

module ZammadAPI
  # Performs the HTTP requests against a Zammad instance.
  #
  # Instances are immutable once built: {#with_on_behalf_of} returns a copy
  # rather than mutating shared state, which makes a single transport safe to
  # use from several threads.
  #
  # @api private
  class Transport
    # The verb shorthands, defined once for the two transports that answer
    # them.
    #
    # {Test::Transport} stands in for this class precisely so that the code
    # under test cannot tell them apart, and it carried its own copy of this
    # loop - so a fifth verb added here would have left the stand-in unable to
    # answer one the real transport had. The same argument as
    # {Transport.relative_path} and {Resources::Base.member_path}: a rule kept
    # in two places is one that gets changed in one of them.
    #
    # @api private
    module Verbs
      # @!method get(path, operation:, query: nil, headers: nil, resource_class: nil)
      # @!method post(path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
      # @!method put(path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
      # @!method delete(path, operation:, query: nil, headers: nil, resource_class: nil)
      # @return [Response]
      %i[get post put delete].each do |verb|
        define_method(verb) do |path, **options|
          request(verb, path, **options) # steep:ignore NoMethod
        end
      end
    end

    include Verbs

    # HTTP methods that are safe to repeat against Zammad: the ones that only
    # read.
    #
    # PUT and DELETE are idempotent in HTTP and used to be here for that
    # reason, but neither is safe to repeat against Zammad. A ticket update
    # carrying an `article` creates that article on every delivery, so an
    # update answered with a 504 and then a 200 added the article twice and
    # sent its e-mail twice, while `update` reported success once. And a
    # DELETE whose first answer was lost was repeated into a 404, so
    # `destroy` raised NotFoundError for a record it had just deleted. A
    # write that fails is reported instead, the way a POST always was, and
    # the caller - who knows what the request carried - decides.
    RETRIABLE_METHODS = %i[get head options].freeze

    # Transient statuses worth retrying.
    RETRIABLE_STATUSES = [429, 500, 502, 503, 504].freeze

    # Socket failures that mean the request ran out of time. Most adapters
    # wrap these into a Faraday error, but not all do, and this gem lets a
    # caller choose the adapter.
    #
    # `timeout` and `socket` are required above for this list and the next
    # one. Both constants used to resolve only because `require 'faraday'`
    # reaches net/http, which loads them - so the day Faraday stops eagerly
    # loading its default adapter, or a caller picks a slimmer one, this class
    # body raises NameError and `require 'zammad_api'` fails before a single
    # request. The Steepfile has declared both libraries all along.
    TIMEOUT_ERRORS = [Errno::ETIMEDOUT, Timeout::Error].freeze

    # Socket failures that mean the instance could not be reached. Listed
    # rather than caught as SystemCallError, so that an unrelated Errno - a
    # logger writing to a full disk, say - is not relabelled as a network
    # problem.
    CONNECTION_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::EPIPE,
      SocketError
    ].freeze

    # TLS failures, for the same reason the socket errors above are listed:
    # most adapters wrap one into a Faraday::SSLError, but this gem lets a
    # caller choose the adapter and not every adapter does. Unlisted, a
    # certificate mismatch through such an adapter left `request` raw, past
    # the `rescue ZammadAPI::TransportError` a caller had written - the one
    # thing the rescue clauses there exist to prevent.
    #
    # Not in {RETRIABLE_EXCEPTIONS}: a rejected certificate is a fact about
    # the instance, not a transient failure, and retrying it only delays the
    # error by the backoff.
    SSL_ERRORS = [OpenSSL::SSL::SSLError].freeze

    # Failures worth retrying. Faraday::RetriableResponse is how the retry
    # middleware signals a retriable status internally and must stay in this
    # list, otherwise it escapes as an unhandled Faraday error.
    #
    # Composed from the two lists above rather than repeating them. Listed
    # by hand, CONNECTION_ERRORS was left out: a transient ECONNRESET through
    # an adapter that wraps it was retried as a Faraday::ConnectionFailed,
    # while the same failure through an adapter that does not raised on the
    # first attempt - so how often a request was retried depended on which
    # adapter a caller picked, and `request` already documents these as
    # failures this class expects to see. The retry middleware still only
    # retries RETRIABLE_METHODS, so a write is not repeated.
    RETRIABLE_EXCEPTIONS = [
      Faraday::RetriableResponse,
      Faraday::ConnectionFailed,
      Faraday::TimeoutError,
      *TIMEOUT_ERRORS,
      *CONNECTION_ERRORS
    ].freeze

    # Substrings that mark a key of what a request carries - its payload, its
    # query, its headers - as holding a credential.
    # Matching on a substring rather than the whole key covers the variants
    # Zammad and OAuth actually send - password_confirm, access_token,
    # refresh_token, client_secret - which an exact-match list silently let
    # through to the log.
    #
    # The same argument reaches further than the first version of this list
    # took it. `password` alone wrote `passwd` and `pwd` out in full, and
    # `private_key` covered exactly one of the key spellings, so `api_key`
    # and a bare `key` went to the log intact. `key` is matched as a word
    # rather than as a substring, so `ssh_key` and `key` are covered while
    # `keyboard` and `monkey_id` are not; `apikey` is spelled out because
    # nothing separates the word there.
    #
    # `cookie` and `authorization` are here for the headers. A raw request
    # takes headers of its own, and the log prints them: `Cookie` carries a
    # session and matched nothing above, so `client.get(path, headers:
    # {'Cookie' => ...})` wrote it out in full at debug level, and
    # `Proxy-Authorization` went the same way. `Authorization` itself never
    # gets this far - {RESERVED_HEADERS} refuses it - but every header named
    # after it carries what it carries.
    #
    # `bind_pw` and `passphrase` are Zammad's own: the password an LDAP
    # source binds with, which sits inside its +preferences+, and the
    # passphrase of a PGP key. Neither matched a word above, so creating
    # either wrote it to the log, and a record of an LDAP source printed
    # it. Both are in the list Zammad filters its own log by, in
    # config/initializers/filter_parameter_logging.rb, and so are `otp` and
    # `salt`. Those two are matched as words, as `key` is: `footprint`
    # holds one and `basalt` the other. `totp` and `hotp` are the two kinds
    # of one-time password, and count.
    #
    # `key` as a word did not see the one in `privateKey`, where no
    # separator stands in front of it. A capital K after a lower-case
    # letter or a digit begins the word as well, which is where camelCase
    # puts it. `hotKeyboard` is left alone, as `keyboard` is.
    SENSITIVE_KEY_PATTERN = /
      password|passwd|pwd|bind_pw|passphrase|token|secret|credential|cookie|authorization|api_?key
      |(?<![a-z])(?:keys?|[ht]?otp|salt)(?![a-z])
      |(?-i:(?<=[a-z0-9])Keys?(?![a-z]))
    /ix

    REDACTED = '[REDACTED]'

    # Characters RFC 3986 leaves unreserved. Everything else is percent-encoded
    # before it goes into a path segment.
    UNRESERVED_IN_PATH = /[^A-Za-z0-9\-._~]/

    # Path segments that name a position rather than a record. Built entirely
    # from unreserved characters, so the encoding above carries them through
    # untouched.
    DOT_SEGMENTS = ['.', '..'].freeze

    # What a record id is written as: the Integer Zammad serves, or text - a
    # String out of a request parameter, a Symbol for a named member such as
    # `users/me`. Everything else has a `to_s` as well, and none of those
    # names a record.
    RECORD_ID_TYPES = [Integer, String, Symbol].freeze

    # What a query value is written as, where it is not a list or a
    # structure: text, an Integer, a Float or a boolean. Each has one
    # spelling a query string can carry and Zammad reads back. No other
    # object does, and `to_s` answers for all of them.
    #
    # Not every Numeric, which is what this list named. A number of another
    # kind prints as something else: `BigDecimal('5')`, an id read from a
    # decimal column, as `0.5e1`, a Rational as `1/2` and a Complex as
    # `1+2i`, and Zammad narrowed by that text. A Float that is not finite
    # has no spelling either: see {.stringify_query_scalar}.
    QUERY_VALUE_TYPES = [String, Symbol, Integer, Float, TrueClass, FalseClass].freeze

    # What a request body is made of, where it is not a list or a structure:
    # the values JSON has a type for, and a Symbol, which the generator
    # writes as text.
    JSON_VALUE_TYPES = [NilClass, String, Symbol, Integer, Float, TrueClass, FalseClass].freeze

    # Objects that are no JSON type and go into a body as they print all the
    # same, because what they print is the value: Zammad reads a time or a
    # date attribute from that text. `date` is required above for this list.
    TEXT_VALUE_TYPES = [Time, Date].freeze

    # A request path that opens with a scheme, which is what makes a URL an
    # absolute one, whatever follows. Any scheme and either case, which is
    # wider than the two lowercase prefixes Faraday itself treats as
    # absolute: what is refused here should not depend on how one Faraday
    # version reads a URL.
    #
    # It did. This asked for `://` after the scheme, so `http:/collect`
    # passed as a relative path, and Faraday 2.9.0 and 2.9.1, which the
    # gemspec allows, join a path to the instance URL the way URI does: the
    # result is `http:/collect`, an absolute URL with no host, and the
    # request leaves for it over plain HTTP with this client's headers
    # attached. Faraday keeps such a path relative from 2.9.2 on, with a
    # `./` in front of it.
    #
    # A path relative to the instance never matches. A colon in the first
    # segment is the one thing RFC 3986 does not let a relative path have,
    # for this reason, and every path Zammad serves opens with `api/`.
    ABSOLUTE_URL = /\A[a-z][a-z0-9+.-]*:/i

    # @return [Config]
    attr_reader :config

    # @return [String, nil] login of the user requests are performed for,
    #   already stringified the way the +From+ header carries it
    attr_reader :on_behalf_of

    # The query parameters a request actually carries.
    #
    # Zammad expects scalar values; booleans and integers are stringified so
    # that Faraday does not encode them as unexpected types.
    #
    # A nil used to be dropped here, which turned `query: {owner_id: nil}` -
    # an entirely reasonable way to write "unassigned" - into an unfiltered
    # index answering with every ticket. Wrong results, no error, nothing to
    # see from the outside. There is no query string that means "this field is
    # null", so saying so is the only answer that can be acted on.
    #
    # Public because {Test} records what a test's client sent, and a stand-in
    # whose recorded values disagree with the wire makes green tests mean less
    # than they appear to.
    #
    # Two spellings of one parameter are refused rather than merged. Keys are
    # stringified here, so `{state_id: 1, 'state_id' => 2}` used to collapse
    # into one parameter and send whichever Hash insertion order put last,
    # dropping the other value without a word - the same silent-wrong-result
    # shape as the dropped nil above, and the reason {ResourceProxy#search}
    # normalises its keywords before they ever reach here.
    #
    # What is not a Hash and converts to one is read as that Hash, at the
    # top and at any depth, as a record reads its attributes: see
    # {DeepCopy.frozen_object}. `ActionController::Parameters` is the case.
    # A +condition+ handed to {ResourceProxy#search} as one went on the wire
    # as its +to_s+, which is the unnarrowed search described below, and a
    # whole +query:+ given as one raised NoMethodError from inside the gem.
    # So did anything else that is no Hash, and that is refused here by
    # name.
    #
    # @api private
    # @param query [Hash]
    # @return [Hash{String => String, Array<String>, Hash}]
    # @raise [ArgumentError] for a query that is not a Hash, for a nil
    #   value, for a value that is neither text, a number, a boolean, a
    #   list nor a structure, for two keys that name the same parameter, or
    #   for a list a query string cannot carry, the last four at any depth
    def self.stringify_query(query)
      hash = Hash.try_convert(query) || raise(ArgumentError, "query needs to be a Hash of parameter names and values, got #{query.class}")

      stringify_query_hash(hash, nil)
    end

    # Stringifies one level of a query, at whatever depth it sits.
    #
    # The duplicate check lives here rather than at the top level alone,
    # because `condition` - which the search endpoints read, and which
    # {ResourceProxy#search} takes as a keyword - is a Hash, and two
    # spellings inside it collapsed exactly
    # the way two spellings at the top level did. The nil check below has been
    # at every depth all along; this is the same kind of rule.
    #
    # The key each name was first seen as is kept, so the message can print
    # both spellings. Naming only the second left the reader to guess the
    # first, which in a query assembled across several merges is the whole of
    # the debugging.
    #
    # @api private
    # @param hash [Hash]
    # @param prefix [String, nil] the parameter path this Hash sits at
    # @return [Hash{String => String, Array, Hash}]
    #
    # A key with an empty name is refused, for the reason a list Rails
    # cannot read back is: a query string has no way to write one. Inside a
    # structure it is written `[]`, which Rails reads as a list - `{list:
    # [{'' => '1'}]}` arrives as `[['1']]` - and at the top level as
    # `=value`, which Rails drops.
    def self.stringify_query_hash(hash, prefix)
      DuplicateKeys
        .normalize(hash, prefix: prefix, &:to_s)
        .to_h do |name, value|
          raise ArgumentError, empty_query_name_message(prefix) if name.empty?

          [name, stringify_query_value(prefix ? "#{prefix}[#{name}]" : name, value)]
        end
    end

    # @api private
    # @return [String]
    def self.empty_query_name_message(prefix)
      found = if prefix
                "query parameter #{prefix} holds a key with an empty name, and a query string writes that as #{prefix}[], which Rails reads as a list"
              else
                'a query parameter has an empty name, and a query string writes that as nothing but its value, which Rails drops'
              end

      "#{found}. Name the key, or put a structure a query string cannot carry in the JSON body of a raw request, such as client.post."
    end

    # Stringifies the scalars and leaves the structure to {QueryEncoder}.
    #
    # A nested value used to be rendered with to_s, so the `condition` that
    # Zammad's search endpoints read - and that {ResourceProxy#search} takes
    # as a keyword - went on the wire as a Ruby inspect string. Zammad could not parse that, dropped the parameter, and
    # answered with an unnarrowed search that nothing marked as unnarrowed.
    # A Hash is written as `condition[ticket.state_id][operator]=is`, which
    # is the shape Rails reads back.
    #
    # The same happened one kind of value further out. Whatever was neither
    # a Hash nor an Array was still rendered with to_s: `ids: Set[1, 2]`
    # went on the wire as `ids=Set[1, 2]` and `ids: (1..3)` as `ids=1..3`,
    # text that names no record and that Zammad narrows by all the same,
    # and a record under a key went as `#<ZammadAPI::Resources::User...>`.
    # Refused, as a record where an id belongs is by
    # {.escape_path_segment}, and for its reason: the answer to such a
    # request is the wrong one, and nothing marks it. See
    # {QUERY_VALUE_TYPES} for what is written.
    #
    # @api private
    # @param key [String] the parameter path, for the error message
    # @param value [Object]
    # @return [String, Array, Hash]
    # @raise [ArgumentError] for a nil value, a value a query string has no
    #   spelling for, or a list it cannot carry
    def self.stringify_query_value(key, value)
      case value
      when nil                then raise ArgumentError, "query parameter #{key} is nil, and Zammad has no way to read that: pass a value, or leave the parameter out"
      when Hash               then stringify_query_hash(value, key)
      when Array              then stringify_query_list(key, value)
      when *QUERY_VALUE_TYPES then stringify_query_scalar(key, value)
      else
        converted = Hash.try_convert(value) || raise(ArgumentError, not_a_query_value_message(key, value))

        stringify_query_hash(converted, key)
      end
    end

    # One of {QUERY_VALUE_TYPES} as text.
    #
    # A Float that is not a number, or not a finite one, is refused. It is
    # of a type the list names and prints as `NaN` or `Infinity`, which is
    # the text Zammad then narrowed by - the result of a division nothing
    # checked, sent as a filter.
    #
    # @api private
    # @return [String]
    # @raise [ArgumentError]
    def self.stringify_query_scalar(key, value)
      if value.is_a?(Float) && !value.finite?
        raise ArgumentError, "query parameter #{key} is #{value}, and a query string has no spelling for a Float that is not finite: " \
                             'it would be sent as that text, and Zammad would narrow by it. Pass a number, or leave the parameter out.'
      end

      wire_text(value, "query parameter #{key}")
    end

    # Names the class and does not quote the value, which for a record is
    # every attribute it carries.
    #
    # @api private
    # @return [String]
    def self.not_a_query_value_message(key, value)
      "query parameter #{key} was given as #{value.class}, and a query string carries text, Integers, Floats and " \
        'booleans, alone or in an Array or a Hash: it would be sent as that object prints, and Zammad would narrow by that ' \
        'text. Pass a Set or a Range as its to_a, a number of another kind as an Integer or a Float, a time as text ' \
        'Zammad reads, such as its iso8601, and a record as its id.'
    end

    # Stringifies a list, and refuses one Rails could not read back as the
    # list it was.
    #
    # A query string does not mark where an element of a list ends, so one
    # Hash after another is a new element only once it is written with a
    # value the one before has a place for too - see {QueryEncoder} - and two
    # with none are read as one: `[{a: 1}, {b: 2}]` arrives as
    # `[{a: 1, b: 2}]`. A Hash with nothing in it is not written at all, and
    # the list arrives one element short. A list directly inside a list is
    # written `[]` like the one around it, and `[[1, 2], [3]]` arrives as
    # three lists of one.
    #
    # Refused, because the other answer is a request that carries something
    # the caller did not write, to an endpoint that then narrows by it.
    #
    # @api private
    # @param key [String] the parameter path, for the error message
    # @param list [Array]
    # @return [Array]
    # @raise [ArgumentError]
    def self.stringify_query_list(key, list)
      elements = list.each_with_index.map { |inner, index| stringify_query_value("#{key}[#{index}]", inner) }

      elements.each_with_index do |element, index|
        reason = QueryEncoder.misread(element, index.zero? ? nil : elements[index - 1])
        raise ArgumentError, misread_element_message("#{key}[#{index}]", reason) if reason
      end

      elements
    end

    # What a query string does to each kind of element {QueryEncoder.misread}
    # names.
    MISREAD_ELEMENTS = {
      merged: 'has no plain value under a key the element before it has as well, and that is all a query string has to say ' \
              'where one element of a list ends and the next begins: Rails would read the two as one. Every condition and ' \
              'every group of conditions in a Zammad selector carries `operator`, which is such a key',
      empty:  'is a Hash with no value in it, and a query string writes nothing for one: Rails would read the list one ' \
              'element short',
      list:   'is a list directly inside a list, and a query string writes both as `[]`: Rails would read each value of ' \
              'the inner list as a list of its own'
    }.freeze
    private_constant :MISREAD_ELEMENTS

    # @api private
    # @return [String]
    def self.misread_element_message(path, reason)
      "query parameter #{path} #{MISREAD_ELEMENTS.fetch(reason)}. To send a structure a query string cannot carry, " \
        'put it in the JSON body of a raw request, such as client.post, which carries it as it is.'
    end

    # Header names this class sets from the configuration, and will not take
    # from a caller.
    #
    # +Authorization+ is built from the credentials {Config} validated, and
    # +From+ is what {Client#on_behalf_of} means. Faraday's authorization
    # middleware leaves a header that is already set alone, so a raw request
    # carrying one of these would have replaced the client's own - quietly,
    # and while {Client#inspect} went on reporting the authentication scheme
    # it was built with. Naming the option that does mean it is the useful
    # answer; overwriting in silence is not.
    RESERVED_HEADERS = {
      'authorization' => 'authentication is configured on the client: pass http_token:, oauth2_token:, or user: and password:, or build a second client with Client#with',
      'from'          => 'the From header is what on_behalf_of sets: use client.on_behalf_of(...) to perform requests for another user'
    }.freeze

    # The part of a header name that is one, from its start: what RFC 9110
    # calls a token, which is letters, digits and these signs. Read from
    # the bytes, as a name is ASCII in every encoding a request can carry.
    HEADER_NAME = /\A[!\#$%&'*+\-.^_`|~0-9A-Za-z]*/

    # The headers a request carries beyond the ones this class sets.
    #
    # Names are downcased, which is what makes two spellings of one header
    # comparable at all: HTTP treats them as the same header, so
    # +{'Accept' => 'a', 'accept' => 'b'}+ would otherwise send whichever Hash
    # order put last and drop the other without a word - the silent drop
    # {DuplicateKeys} exists to refuse.
    #
    # A name that is not one is refused: see {.header_name}.
    #
    # Values are stringified for the reason {#with_on_behalf_of} stringifies
    # the +From+ scope: a header is text on the wire, and a value of another
    # type reaches Net::HTTP intact and dies there with
    # `undefined method 'strip' for an instance of Integer`.
    #
    # Public for the same reason as {.stringify_query}: {Test} records what a
    # request would have carried, and a stand-in whose recorded values
    # disagree with the wire makes green tests mean less than they appear to.
    #
    # @api private
    # @param headers [Hash]
    # @return [Hash{String => String}]
    # @raise [ArgumentError] for a name that is not a header name, a nil
    #   value, a value that is not text, two spellings of one header, or a
    #   header this class sets itself
    def self.stringify_headers(headers)
      DuplicateKeys
        .normalize(headers, noun: 'header') { header_name(it) }
        .to_h { |name, value| [name, stringify_header_value(name, value)] }
    end

    # A header name as it is compared and sent: downcased, and refused
    # where it is not a name.
    #
    # Only the value was checked. A name went to the adapter as it was, and
    # the Net::HTTP that ships with Ruby 3.4 and 4.0 writes it to the socket
    # as it is: `headers: {"X-A: 1\r\nFrom: admin@example.com\r\nX-B" =>
    # 'v'}` sent a From header of its own, which is the one {RESERVED_HEADERS}
    # refuses by name, and an Authorization went the same way. `'From '`
    # passed that lookup too, and was sent as `From : v`, and a name with
    # nothing in it as `: v`. net-http refuses a control character or a
    # colon from 0.10.0 on, with an ArgumentError of its own that quotes the
    # name, raised after the request was logged, and takes the other two.
    #
    # @api private
    # @param name [Object]
    # @return [String]
    # @raise [ArgumentError]
    def self.header_name(name)
      text  = name.to_s
      bytes = text.b
      start = bytes[HEADER_NAME].to_s
      raise ArgumentError, not_a_header_name_message(start) if start.empty? || start.bytesize != bytes.bytesize

      text.downcase
    end

    # Quotes the name as far as it is one, and no further.
    #
    # @api private
    # @param start [String] the part of the name that is a name
    # @return [String]
    def self.not_a_header_name_message(start)
      found = start.empty? ? 'a header name is empty or begins' : "the header name that begins #{start.inspect} goes on"

      "#{found} with a character no header name carries: a name is letters, digits and signs such as - and _, " \
        'without a space, a colon or a line break. The rest of it is not quoted here: what follows a line break in a ' \
        'name would be sent as header lines of their own, and may be a credential.'
    end

    # @api private
    # @return [String]
    def self.stringify_header_value(name, value)
      reserved = RESERVED_HEADERS[name]
      raise ArgumentError, "header #{name} is set by this client, not by a request: #{reserved}" if reserved
      raise ArgumentError, "header #{name} is nil, and a header is always text: pass a value, or leave the header out" if value.nil?
      raise ArgumentError, "header #{name} was given as #{value.inspect}, and a header is always text: pass a String" if !value.is_a?(String) && !value.is_a?(Symbol) && !value.is_a?(Numeric)

      text = wire_text(value, "header #{name}")
      raise ArgumentError, "header #{name} holds a line break, which a header cannot carry: #{LINE_BREAK_ADVICE}" if line_break?(text)

      stripped(text)
    end

    # What to do about a line break in a header value, said wherever one is
    # refused.
    LINE_BREAK_ADVICE = 'the value is not quoted here, as it may be a credential. Read it without the line break - ' \
                        'a value read from a file usually ends in one, which is taken, but one inside it is not.'

    # Whether a header value holds a line break no header can carry.
    #
    # Net::HTTP strips the whitespace around a header value and refuses one
    # with a line break left in it, with an ArgumentError that quotes the
    # value: `http_token: "abc\ndef"` was taken when the client was built
    # and raised at its first request, neither as a {ZammadAPI::Error} nor
    # where the token was configured, with the token in the message. The
    # +From+ scope and a raw request's headers went the same way. A line
    # break at either end is stripped there, so a token read from a file
    # with its newline still on works, and is still taken.
    #
    # Asked of the bytes. +strip+ raises for text that holds a byte sequence
    # its encoding does not allow, and that error was read here as "no line
    # break": `http_token: "abc\xFF\ndef"` was taken, and an adapter that
    # does not check a header itself sent what follows the break as a header
    # of its own. A line break is the same byte in every encoding ASCII is a
    # part of, and binary text has no sequence that is not allowed.
    #
    # Asked of a String {.wire_text} has had, as {BLANK} is: the bytes of
    # UTF-16 are not the bytes a request carries.
    #
    # @api private
    # @param text [String]
    # @return [Boolean]
    def self.line_break?(text) = /[\r\n]/.match?(text.b.strip)

    # A header value without what Net::HTTP strips from around it.
    #
    # {.line_break?} takes a value that only ends in a line break, because
    # Net::HTTP strips one before it writes the header. That is the default
    # adapter and not the only one, and the value was handed on with the
    # break still on it: to an adapter that writes a header as it stands,
    # the break ends the line, and `\r\n\r\n` ends the headers. Stripped
    # here, every adapter is handed the value Net::HTTP sent.
    #
    # Of the bytes, as {.line_break?} asks of them and for its reason. Text
    # in an encoding ASCII is no part of is left as it is: its bytes are not
    # the ones a request carries, see {.wire_text}.
    #
    # @api private
    # @param text [String]
    # @return [String] the text itself where there is nothing to strip
    def self.stripped(text)
      return text if !text.encoding.ascii_compatible?

      bare = text.b.strip
      bare.bytesize == text.bytesize ? text : bare.force_encoding(text.encoding)
    end

    # The +From+ scope as a transport holds it: text, and a copy of its own.
    #
    # Text, because a user id is a documented way to name the user and
    # arrives as an Integer, which reached Net::HTTP intact and died there
    # with `undefined method 'strip' for an instance of Integer`.
    #
    # A copy, because `String#to_s` hands back the receiver. The scoped
    # client held the caller's own String, so a login buffer that was reused
    # after `client.on_behalf_of(login)` changed who every later request from
    # that client was performed for - the one thing a scope exists to pin.
    # Copied rather than interned, for the reason {Config} copies what it is
    # given: nothing a caller passed in should outlive what holds it.
    #
    # Public for the same reason as {.stringify_query}: {Test} carries the
    # scope the way this class does, so that what it records is what the
    # header would have carried.
    #
    # An identifier that names nobody is refused here, the one place every
    # way to a +From+ header goes through, rather than only by
    # {Client#on_behalf_of}. Zammad skips a header with nothing in it, so a
    # transport scoped to one sent every request as the account it
    # authenticates as. Nothing in it is what Rails calls blank, which
    # counts Unicode spaces as well as ASCII ones: Zammad asks
    # `request_header_from.blank?`.
    #
    # So is one that is neither text nor an Integer. Every object has a
    # `to_s`, and `client.on_behalf_of(user)`, with the record where its
    # login belongs, built a client whose From header read
    # `#<ZammadAPI::Resources::User:0x...>`. The types are the ones a
    # record id is written as: see {RECORD_ID_TYPES}.
    #
    # @api private
    # @param identifier [String, Integer, nil] login, email or user id
    # @return [String, nil] frozen, or nil for no scope
    # @raise [ArgumentError] for an identifier that is neither text nor an
    #   Integer, or has nothing in it
    def self.stringify_on_behalf_of(identifier)
      return nil if identifier.nil?
      raise ArgumentError, not_an_identifier_message(identifier) if RECORD_ID_TYPES.none? { identifier.is_a?(it) }

      text = stripped(wire_text(identifier, 'on_behalf_of'))
      raise ArgumentError, blank_on_behalf_of_message(identifier) if BLANK.match?(text)
      raise ArgumentError, "on_behalf_of holds a line break, which the From header cannot carry: #{LINE_BREAK_ADVICE}" if line_break?(text)

      text.dup.freeze
    end

    # What Rails calls blank, for a String: nothing but whitespace, Unicode
    # spaces included. +strip+ removes the ASCII ones only, so a no-break
    # space passed a check built on it and was then read as nothing.
    #
    # Asked of a String {.wire_text} has had: the pattern is US-ASCII, and
    # matching it against text in an encoding ASCII is no part of raises
    # Encoding::CompatibilityError.
    BLANK = /\A[[:space:]]*\z/

    # A value as text a request can carry: in UTF-8 where it was given in an
    # encoding ASCII is no part of, such as UTF-16.
    #
    # Such a String cannot be joined to the ASCII around it. Faraday's
    # escaping of a query value and Net::HTTP's writing of a header both
    # raised Encoding::CompatibilityError for one, as did {BLANK} asked of a
    # +From+ scope or a search keyword: neither a {ZammadAPI::Error} nor the
    # ArgumentError a malformed value is refused with, and for a non-blank
    # value, one that had nothing wrong with it but its encoding. Converted,
    # it is the same text, in the encoding Zammad reads.
    #
    # An encoding ASCII is a part of is left as it was, binary included: its
    # bytes are what went on the wire, and still are.
    #
    # @api private
    # @param value [Object]
    # @param name [String] what the value is, for the error message
    # @return [String]
    # @raise [ArgumentError] for text that cannot be converted to UTF-8
    def self.wire_text(value, name)
      text = value.to_s
      return text if text.encoding.ascii_compatible?

      begin
        text.encode(Encoding::UTF_8)
      rescue EncodingError
        raise ArgumentError, "#{name} was given as #{text.encoding} text that cannot be converted to UTF-8, which is what " \
                             'a request carries: it holds a byte sequence that is not valid in its own encoding.'
      end
    end

    # Names the class and does not quote the identifier, which for a record
    # is every attribute it carries.
    #
    # @api private
    # @return [String]
    def self.not_an_identifier_message(identifier)
      "on_behalf_of needs the login, email address or id of a user, as a String or an Integer, and was given #{identifier.class}: " \
        'the From header would carry that object as it prints, which names no user. To act for a user you hold a record of, pass its id.'
    end

    # @api private
    # @return [String]
    def self.blank_on_behalf_of_message(identifier)
      "on_behalf_of needs the login, email address or id of a user, and was given #{identifier.inspect}. " \
        'Zammad reads a From header with nothing in it as no header at all, so every request would be performed ' \
        'as the account this client authenticates as, with nothing to say the scope was missing.'
    end

    # Percent-encodes one segment of a request path.
    #
    # Record ids are pasted into the path, and an id taken straight from a
    # request parameter used to be pasted in whole: `find("1/../../api/v1/
    # users/1")` resolved to the users endpoint, so the parameter, not the
    # call, chose which records the verb applied to. Encoding everything
    # outside the unreserved set keeps a separator inside the segment it was
    # written in, and a caller that really means a sub-path can spell it out
    # with the raw request methods.
    #
    # A dot segment is refused rather than encoded. `.` and `..` are unreserved
    # all the way through, so the encoding below returns them exactly as they
    # arrived and `find('..')` still resolved one path level up - onto the
    # index endpoint, and through a has_many path onto every article on the
    # instance offered as one ticket's. Percent-encoding the dots would hold
    # them inside the segment here, but a proxy that normalises a path before
    # routing it would undo that, and no Zammad record is named for one.
    #
    # Anything that is not an id is refused rather than printed. `to_s`
    # answers for every object, so a record where its id belongs was pasted
    # in as it inspects: `exists?(ticket)` asked for
    # `tickets/%23%3CZammadAPI%3A%3AResources%3A%3ATicket...%3E`, was told
    # 404 about a path that names nothing, and answered false for a ticket
    # that exists, while `destroy(ticket)` raised NotFoundError for one that
    # was right there. The message names the class and does not quote the
    # value, which for a record is every attribute it carries.
    #
    # Public for the same reason as {.stringify_query}: {Test} builds the
    # paths it records with it.
    #
    # @api private
    # @param value [Integer, String, Symbol, nil]
    # @return [String]
    # @raise [ArgumentError] when there is nothing to send, when the value
    #   is not an id at all, or when the id navigates instead of naming a
    #   record
    def self.escape_path_segment(value)
      raise ArgumentError, not_a_record_id_message(value) if !value.nil? && RECORD_ID_TYPES.none? { value.is_a?(it) }

      segment = value.to_s
      raise ArgumentError, 'a record id is required, and this one is empty' if segment.empty?
      raise ArgumentError, "#{segment.inspect} points at another endpoint rather than naming a record" if DOT_SEGMENTS.include?(segment)

      segment.gsub(UNRESERVED_IN_PATH) { |character| character.bytes.map { format('%%%02X', it) }.join }
    end

    # @api private
    # @return [String]
    def self.not_a_record_id_message(value)
      "a record id is an Integer or a String, and this one is #{value.class}: it would go into the request path as " \
        'that object prints, which names no record. To address a record you hold, pass its id.'
    end

    # Strips the leading slashes from a path so that it resolves against the
    # instance URL rather than against the host.
    #
    # {Config#url} always ends in a slash and every request path is appended
    # relative to it, so a leading slash would drop the sub-path of a Zammad
    # served from one - `https://host/zammad/` + `/api/v1/tickets` resolves to
    # `https://host/api/v1/tickets`.
    #
    # A path that names a host of its own is refused. Faraday lets an absolute
    # URL replace the instance URL and still attaches this client's headers,
    # so `client.get('https://other.example/collect')` - a link lifted from a
    # response body, say - sent the access token and the on_behalf_of scope
    # to that host. Record ids are held inside their segment by
    # {.escape_path_segment}; this is the same escape, one level up. The
    # message does not quote the path, which may carry a secret of its own.
    # What counts as absolute is {ABSOLUTE_URL}: a path that opens with a
    # scheme, with or without a host after it.
    #
    # Public for the same reason as {.stringify_query} and
    # {.escape_path_segment}: {Client} and {Test} both apply this rule, the
    # latter to decide which stub a request matches, and a path rule kept in
    # three places is one that gets changed in one of them - at which point
    # the stand-in quietly stops matching what the client sends.
    #
    # A path that cannot be read as a URL is refused here as well, which is
    # where it stops being Faraday's to refuse. Faraday reads the path with
    # URI when the request is built, and URI raises an error of its own for
    # one it cannot read: `client.get('api/v1/tägs')` and
    # `client.get(' api/v1/x')` left as URI::InvalidURIError, which is
    # neither a {ZammadAPI::Error} nor the ArgumentError a raw request
    # documents for a path, so no rescue a caller was told to write caught
    # it. And it was raised after the request had been logged, leaving a line
    # for a request that never left - what {#perform} stringifies the query
    # and the headers first to prevent.
    #
    # @api private
    # @param path [Object]
    # @return [String]
    # @raise [ArgumentError] for an absolute URL, or a path that cannot be
    #   read as a URL
    def self.relative_path(path)
      relative = path.to_s.sub(%r{\A/+}, '')
      if ABSOLUTE_URL.match?(relative)
        raise ArgumentError, 'a request path is relative to the instance URL, and this one opens with a scheme, which makes it an ' \
                             "absolute URL: sending it would hand this client's credentials to another host. Pass the path alone, " \
                             "such as 'api/v1/tickets'."
      end

      refuse_unreadable_path!(relative)
      relative
    end

    # Reads a path the two ways Faraday will: the whole of it as a URL, and
    # a query string written into it as parameters.
    #
    # The second can fail where the first does not. `?a=1&a[b]=2` names one
    # parameter as a value and as a structure, and decoding it raised
    # TypeError from inside the connection.
    #
    # Neither message quotes the path, for the reason the one above does
    # not, and neither passes on the error underneath, which does quote it:
    # not its message, and not the error itself as the cause, which Ruby
    # attaches to an error raised in a rescue and prints with it, so an
    # exception tracker recorded the path, credentials and all.
    #
    # @api private
    # @param relative [String]
    # @return [void]
    # @raise [ArgumentError]
    def self.refuse_unreadable_path!(relative)
      begin
        URI.parse(relative)
      rescue URI::InvalidURIError
        raise ArgumentError, unreadable_path_message(relative), cause: nil
      end

      begin
        QueryEncoder.decode(relative.partition('#').first.partition('?').last)
      rescue TypeError, Faraday::Error
        raise ArgumentError, 'the query string written into this request path cannot be read as parameters: it names one of them ' \
                             'both as a value and as a structure, or nests them deeper than a query string is read. ' \
                             'Pass the parameters as query: instead, which takes them as a Hash.', cause: nil
      end
    end

    # @api private
    # @return [String]
    def self.unreadable_path_message(relative)
      found = relative.ascii_only? ? 'a space, or another character a URL does not allow, or a % that begins no escape' : 'a character outside ASCII'

      "a request path is written the way a URL is, and this one cannot be read as one: it holds #{found}. " \
        'Percent-encode what a URL cannot hold as it is - a space is %20, and ä is %C3%A4 - ' \
        'or pass a parameter as query:, which encodes its value.'
    end

    # A request path as it may be printed: with the credentials of a query
    # string written into it blanked.
    #
    # A raw request may carry its query in the path -
    # `client.get('api/v1/users/password_reset_verify?token=...')` is how the
    # Zammad documentation spells that endpoint - and the path is printed in
    # three places: the two log lines for a request, the message of a
    # timeout, and the operation a raw request is named by in every error it
    # raises. The `query:` Hash is redacted by key before it is logged, and
    # the same parameter written into the path went out in full in all
    # three.
    #
    # Redacted by name, as the Hash is, and written back as it was given
    # otherwise. A name that cannot be decoded cannot be read, so its value
    # is blanked rather than assumed to be harmless.
    #
    # A fragment is blanked whole. What follows a +#+ is no part of the
    # request, and Faraday leaves it out of what it sends, but it was
    # printed with the path: `api/v1/x#token=...` has no +?+ to be read as a
    # query from, and came back as it stood, and after a query the fragment
    # was printed as the tail of the last value. Blanked and not dropped, so
    # that what is printed still says the path was written with one.
    #
    # Public for {Client}, which names a raw request by its path.
    #
    # @api private
    # @param path [Object]
    # @return [String]
    def self.redact_path(path)
      sent, hash, = path.to_s.partition('#')
      base, mark, query = sent.partition('?')
      printed = mark.empty? ? base : "#{base}?#{query.split('&', -1).map { redact_query_pair(it) }.join('&')}"

      hash.empty? ? printed : "#{printed}##{REDACTED}"
    end

    # One stretch of a query string between two +&+, as it may be printed.
    #
    # Usually that is one parameter. Rack 2 ends a parameter at a +;+ as
    # well, though, and Zammad ran on it up to 7.0: there
    # `?page=2;token=...` carries a token, and read as one parameter it was
    # the tail of a value named +page+ and printed. Rack 3, and Zammad
    # since 7.1, reads the +;+ as part of the value.
    #
    # Both readings are covered, since nothing here knows which server is
    # asked. A credential the stretch opens with is blanked to its end, the
    # +;+ and what follows included, which is the whole of its value as
    # Rack 3 reads it. Any other is followed past each +;+, and a parameter
    # named like a credential there is blanked as far as the next one,
    # which is where Rack 2 ends it.
    #
    # @api private
    # @return [String]
    def self.redact_query_pair(pair)
      return blank_query_value(pair) if credential_parameter?(pair)

      first, separator, later = pair.partition(';')
      return pair if separator.empty?

      "#{first};#{later.split(';', -1).map { credential_parameter?(it) ? blank_query_value(it) : it }.join(';')}"
    end

    # Whether +name=value+ is named like a credential. A name that cannot
    # be decoded cannot be read, and counts as one.
    #
    # @api private
    # @return [Boolean]
    def self.credential_parameter?(parameter)
      name, mark, = parameter.partition('=')
      return false if mark.empty?

      decoded = begin
        URI.decode_www_form_component(name)
      rescue ArgumentError
        nil
      end

      decoded.nil? || SENSITIVE_KEY_PATTERN.match?(decoded)
    end

    # @api private
    # @return [String]
    def self.blank_query_value(parameter) = "#{parameter.partition('=').first}=#{REDACTED}"

    # A structure as it may be printed: with the value under every key that
    # names a credential blanked, at any depth. See {SENSITIVE_KEY_PATTERN}
    # for which keys those are.
    #
    # Public for {Resources::Base#inspect}. This was the log's own rule, and
    # a record printed the same attributes with nothing applied to them.
    #
    # @api private
    # @param value [Object]
    # @return [Object] a copy where anything was blanked, or holds a Hash or
    #   an Array
    def self.redact(value)
      case value
      when Hash  then value.to_h { |key, nested| [key, SENSITIVE_KEY_PATTERN.match?(key.to_s) ? REDACTED : redact(nested)] }
      when Array then value.map { redact(it) }
      else value
      end
    end

    # The bytes a request body goes out as.
    #
    # Encoded here rather than left to Faraday's JSON middleware, because a
    # body that cannot be encoded raised JSON::GeneratorError from inside the
    # stack and nothing mapped it: `client.post(path, body: {data:
    # File.binread('a.png')})` with the bytes not Base64-encoded, or any body
    # holding a Float::NAN, went past the +rescue ZammadAPI::Error+ every
    # caller is told to write, and a record whose +save+ carried the same
    # value took the same way out. It is also encoded before the request is
    # logged, for the reason the query and the headers are stringified
    # first: a refused body leaves no line claiming a request that was never
    # made.
    #
    # A String is passed through, as the middleware passes it: it is the
    # caller saying the body is already encoded.
    #
    # Public for the same reason as {.stringify_query}: {Test} refuses what
    # the wire would refuse.
    #
    # @api private
    # @param body [Object]
    # @param operation [String] description used in the error message
    # @param resource_class [Class, nil] used in the error message
    # @return [String, nil] nil for a request without a body
    # @raise [Error] when the body cannot be encoded as JSON
    def self.encode_body(body, operation:, resource_class: nil)
      return body if body.nil? || body.is_a?(String)

      JSON.generate(json_value(body, nil))
    rescue JSON::JSONError => e
      raise Error, "Can't #{Error.subject_for(operation, resource_class)}: the request body cannot be encoded as JSON (#{e.message}). " \
                   'Every value has to be a JSON type, and text has to be valid UTF-8: Base64-encode binary data such as an ' \
                   'attachment, and leave out a Float that is NaN or infinite.'
    end

    # A body as the generator may be handed it: every value in it one JSON
    # has a type for, or an object that says what it is written as.
    #
    # The generator writes whatever is neither as the object's `to_s`, and
    # every object has one. `client.users.create(login: 'x', role_ids:
    # Set[1, 2])` sent `"role_ids":"Set[1, 2]"`, a String where the list
    # belongs, and a Struct went as `#<struct ...>`. Nothing raised, and
    # what Zammad made of the text was the answer. It is what
    # {.stringify_query_value} refuses in a query, one request part over.
    #
    # @api private
    # @param value [Object]
    # @param key [Object, nil] the key the value sits under, for the error
    #   message
    # @return [Object]
    # @raise [JSON::GeneratorError] for a value JSON has no type for, which
    #   {.encode_body} words like any other body that cannot be encoded
    def self.json_value(value, key)
      case value
      when *JSON_VALUE_TYPES then value
      when Hash              then value.to_h { |name, nested| [name, json_value(nested, name)] }
      when Array             then value.map { json_value(it, key) }
      else json_object(value, key)
      end
    end

    # What is none of the above, as what the object itself says it is, in
    # the order the object is asked.
    #
    # What converts to a Hash is that Hash, as it is for a record's
    # attributes: see {DeepCopy.frozen_object}. The generator has no
    # spelling for `ActionController::Parameters` either, so `client.post(path,
    # body: permitted)` sent its `to_s` in place of an object, password
    # included, and a body holding one sent it under the key.
    #
    # An object with a `to_json` of its own is left to the generator, which
    # calls it: a record of this gem, or a value object written to be sent.
    #
    # An object with an `as_json` is what that returns, and what it holds is
    # walked in turn. ActiveSupport gives every object one and builds its
    # `to_json` on it, which is what 1.x sent a body with. `JSON.generate`
    # does not ask it, so in a Rails app `role_ids: Set[1, 2]` was the list
    # under 1.x and the String above here, `ttl: 2.days` was `"172800"`, and
    # a model went as `#<User ...>`.
    #
    # A Time and a Date are left to print: see {TEXT_VALUE_TYPES}.
    #
    # @api private
    # @return [Object]
    # @raise [JSON::GeneratorError]
    def self.json_object(value, key)
      converted = Hash.try_convert(value)
      return json_value(converted, key) if converted
      return value if writes_own_json?(value)

      described = value.respond_to?(:as_json) ? value.as_json : value
      case described
      when *JSON_VALUE_TYPES, Hash, Array then json_value(described, key)
      when *TEXT_VALUE_TYPES              then described
      else raise JSON::GeneratorError, not_a_json_value_message(value, key)
      end
    end

    # Whether an object has a `to_json` of its own, and not the one the
    # generator gives every object - or ActiveSupport, around that one -
    # which writes the object's `to_s`.
    #
    # Asked of where the method is defined, which is the same place for
    # every object that has only the generic one, whichever of the two
    # libraries put it there. And asked through Kernel, because a Struct or
    # a Data may have a member called `method`.
    #
    # @api private
    # @return [Boolean]
    def self.writes_own_json?(value)
      Kernel.instance_method(:method).bind_call(value, :to_json).owner != Object.instance_method(:to_json).owner
    end

    # Names the class and the key, and does not quote the value, as
    # {.not_a_query_value_message} does not.
    #
    # @api private
    # @return [String]
    def self.not_a_json_value_message(value, key)
      "#{key.nil? ? 'it' : "its key #{key}"} was given as #{value.class}, which is no JSON type and would be sent as that " \
        'object prints: pass a Set or a Range as its to_a, a number as an Integer or a Float, and any other object as ' \
        'a Hash of what it holds'
    end

    # What the retry middleware is built with.
    #
    # +max_interval+ is what bounds a wait. The retry middleware sleeps for
    # whatever a +Retry-After+ header says, and its own ceiling defaults to
    # no ceiling at all: a maintenance page answering 503 with
    # +Retry-After: 3600+ held the calling thread for an hour per retry,
    # whatever +timeout+ and +retry_interval+ said, before raising the error
    # it could have raised at once.
    #
    # +timeout+ is the bound, because it is already how long this client
    # was told it may wait for an answer. A +Retry-After+ within it is
    # honoured; a longer one is not waited out, and the response it came
    # with is reported as the error it is, with the figure still readable
    # from {RateLimitError#retry_after}.
    #
    # Public for {.retried?}, which {Test} asks.
    #
    # @api private
    # @param config [Config]
    # @return [Hash{Symbol => Object}]
    def self.retry_options(config)
      {
        max:                 config.retries,
        interval:            config.retry_interval,
        max_interval:        config.timeout,
        interval_randomness: 0.5,
        backoff_factor:      2,
        retry_statuses:      RETRIABLE_STATUSES,
        methods:             RETRIABLE_METHODS,
        exceptions:          RETRIABLE_EXCEPTIONS
      }
    end

    # Whether a request answered with +response+ is one the retry middleware
    # sends again, while it has attempts left.
    #
    # Public for {Test}, for the reason {.stringify_query} is: a stand-in
    # that raised for the first 503 a +GET+ was answered with, where the
    # wire asks again, made a test of code that leans on the retry pass or
    # fail the other way round from production.
    #
    # The wait is asked of the middleware itself, built from the options
    # above, and not worked out a second time here. It answers nil where a
    # +Retry-After+ - or a +RateLimit-Reset+, or either as a date - asks
    # for longer than it may wait, which is the one response with a
    # retriable status that it does not send again. A copy of that reading
    # is the kind that gets changed in one place.
    #
    # @api private
    # @param config [Config]
    # @param method [Symbol]
    # @param response [Response]
    # @return [Boolean]
    def self.retried?(config, method, response)
      options = retry_options(config)
      return false if !options[:methods].include?(method) || !options[:retry_statuses].include?(response.status)

      !Faraday::Retry::Middleware.new(nil, options).calculate_sleep_amount(1, { response_headers: Faraday::Utils::Headers.new(response.headers) }).nil?
    end

    # What {#inspect} says of a transport or of a client, for a JSON
    # encoder. Public for {Client#as_json}, whose transport may be another
    # kind than this one.
    #
    # @api private
    # @param config [Config]
    # @param on_behalf_of [String, nil]
    # @return [Hash{Symbol => Object}]
    def self.description(config, on_behalf_of)
      { url: config.redacted_url, auth: config.authentication_scheme, on_behalf_of: on_behalf_of }.compact
    end

    # @param config [Config]
    def initialize(config)
      @config       = config
      @on_behalf_of = nil
      @connection   = build_connection
    end

    # Returns a copy of this transport that sends the +From+ header.
    #
    # The scope is stringified here rather than at the point the header is
    # set, so that {Test} records the value the wire would carry: an Integer
    # used to die inside Net::HTTP while the test kit accepted it happily.
    # See {.stringify_on_behalf_of} for what is held.
    #
    # @param identifier [String, Integer, nil] login, email or user id
    # @return [Transport]
    def with_on_behalf_of(identifier)
      copy = dup
      copy.instance_variable_set(:@on_behalf_of, Transport.stringify_on_behalf_of(identifier))
      copy
    end

    # Returns a transport of this kind configured with +config+, keeping any
    # {#with_on_behalf_of} scope.
    #
    # {Client#with} goes through here rather than building a Transport itself,
    # so that a client whose transport was replaced - the test kit's stand-in,
    # say - derives another of the same kind instead of silently reverting to
    # a real HTTP one.
    #
    # @param config [Config]
    # @return [Transport]
    def with_config(config) = self.class.new(config).with_on_behalf_of(on_behalf_of)

    # Says where this transport points and how it authenticates, and nothing
    # else.
    #
    # Left to Ruby, this printed the instance variables, and one of them is
    # the Faraday connection: its proxy options carry the proxy password and
    # its middleware stack carries the arguments it was built with, the
    # access token among them. Every record holds its transport, so that was
    # one +inspect+ away from any of them. Defining this covers +pp+ as well,
    # which uses an +inspect+ a class defines for itself.
    #
    # @return [String]
    def inspect
      "#<#{self.class.name} url=#{config.redacted_url.inspect} auth=#{config.authentication_scheme}#{" on_behalf_of=#{on_behalf_of.inspect}" if on_behalf_of}>"
    end

    # The transport for a JSON encoder: what {#inspect} says, and nothing
    # else.
    #
    # ActiveSupport serializes an object as its instance variables, and
    # here one of them is the Faraday connection, for which {#inspect} has
    # said why it is not printed. Every record holds its transport.
    #
    # @return [Hash{Symbol => Object}]
    def as_json(*) = Transport.description(config, on_behalf_of)

    # @param state [JSON::State, nil] passed by +JSON.generate+
    # @return [String] {#as_json} as a JSON object
    def to_json(state = nil) = as_json.to_json(state)

    # Performs a request and raises on anything but a 2xx response.
    #
    # @param method [Symbol] +:get+, +:post+, +:put+ or +:delete+
    # @param path [String] path relative to {Config#url}
    # @param operation [String] description used in error messages
    # @param query [Hash, nil] query string parameters
    # @param body [Hash, nil] request payload, encoded as JSON
    # @param headers [Hash, nil] request headers, beyond the ones this class
    #   sets from the configuration
    # @param resource_class [Class, nil] used in error messages
    # @return [Response]
    # @raise [ResponseError] for non-2xx responses
    # @raise [TimeoutError] when the request timed out
    # @raise [ConnectionError] when the instance was unreachable
    # @raise [IncompleteResponseError] when the connection was closed before
    #   the body of a 2xx response had arrived
    #
    # @raise [Error] when the body cannot be encoded as JSON
    #
    # Every failure leaves here as a {ZammadAPI::Error}. The bare socket
    # errors are caught alongside the Faraday ones because they are already
    # in {RETRIABLE_EXCEPTIONS}, which is this class saying it expects to see
    # them: an adapter that does not wrap them used to let them out raw once
    # the retries were spent, past every rescue a caller had written.
    def request(method, path, operation:, query: nil, body: nil, headers: nil, resource_class: nil)
      # Here as well as in {Client}, because this is the one door every
      # request goes through, whichever caller built the path.
      path     = Transport.relative_path(path)
      payload  = Transport.encode_body(body, operation: operation, resource_class: resource_class)
      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = decode(perform(method, path, query, payload, headers))
      log_response(method, path, response, started)

      return whole(response, operation) if response.success?

      raise ResponseError.build(response, operation: operation, resource_class: resource_class)
    rescue Faraday::TimeoutError, *TIMEOUT_ERRORS => e
      raise TimeoutError, "Can't #{operation}: request to #{Transport.redact_path(path)} timed out (#{e.message})"
    rescue Faraday::SSLError, *SSL_ERRORS => e
      raise ConnectionError, "Can't #{operation}: TLS handshake with #{config.redacted_url} failed (#{e.message})"
    rescue Faraday::ConnectionFailed, *CONNECTION_ERRORS => e
      # Before it is called unreachable, because one kind of connection
      # failure is a timeout. See #timed_out?.
      raise TimeoutError, "Can't #{operation}: connecting to #{config.redacted_url} timed out (#{e.message})" if timed_out?(e)

      raise ConnectionError, "Can't #{operation}: #{config.redacted_url} is unreachable (#{e.message})"
    end

    private

    # A Content-Length that can be compared: one figure, and nothing else.
    # Two that were sent arrive joined by a comma, and say nothing certain.
    CONTENT_LENGTH = /\A\d+\z/
    private_constant :CONTENT_LENGTH

    # A 2xx response, once its body is known to have arrived: see
    # {#missing_bytes}.
    #
    # Raised with the response, as the one {ConnectionError} that has one:
    # Zammad answered, so a write was applied, and {Resources::Base#save!}
    # and {Resources::Base#destroy} have to hear that to settle the record.
    #
    # @return [Response]
    # @raise [IncompleteResponseError]
    def whole(response, operation)
      missing = missing_bytes(response)
      return response if missing.nil?

      raise IncompleteResponseError.new(
        "Can't #{operation}: the response from #{config.redacted_url} ended #{missing} bytes short of the " \
        "#{response.headers['content-length']} its Content-Length announces, so the connection was closed " \
        'before the body had arrived',
        response: response
      )
    end

    # How many bytes of its body a response stopped short by, where it did.
    #
    # A body framed by Content-Length ends where the count is reached, or
    # where the connection does. Net::HTTP takes the second for the first
    # without a word - its +ignore_eof+ is on by default - so a download
    # the connection dropped under came back as the file:
    # {Resources::TicketArticleAttachment#download} returned the first ten
    # bytes of a thousand, and whatever wrote them to disk wrote a file that
    # opens as a broken one. A chunked body cut short did raise, and a JSON
    # one that no longer parses is refused where it is decoded, so this was
    # the one response that came back wrong and looked right.
    #
    # Asked only where the bytes in hand are the bytes that were counted. A
    # body under a Content-Encoding may have been decoded on the way here,
    # by an adapter that leaves both headers as they arrived. The default
    # one does: Net::HTTP drops the one and corrects the other while it
    # reads the body, and Faraday has taken its copy of the headers by
    # then. So a compressed body cut short is not caught here, and
    # {Resources::TicketArticleAttachment#download} asks for its file
    # uncompressed. A body under a Transfer-Encoding is not framed by the
    # count at all, and a 204 has no body whatever a header beside it says.
    #
    # Only a body that is short. One that is longer was not cut off.
    #
    # @return [Integer, nil] nil for a response that is whole, or that
    #   cannot be told
    def missing_bytes(response)
      headers   = response.headers
      announced = headers['content-length']
      return nil if announced.nil? || !CONTENT_LENGTH.match?(announced)
      return nil if response.status == 204 || headers.key?('content-encoding') || headers.key?('transfer-encoding')

      missing = announced.to_i - response.raw_body.bytesize
      missing.positive? ? missing : nil
    end

    # Whether a connection failure is a timeout underneath.
    #
    # An exceeded +open_timeout+ is raised by Net::HTTP as Net::OpenTimeout,
    # and the default adapter wraps that into Faraday::ConnectionFailed along
    # with every other failure to connect. So it was reported as "is
    # unreachable (execution expired)", a ConnectionError, and skipped the
    # +rescue ZammadAPI::TimeoutError+ that is documented to catch an
    # exceeded +open_timeout+.
    #
    # Both places an adapter can leave the original are looked at: Faraday's
    # own +wrapped_exception+, and the +cause+ Ruby records for an error
    # raised while another was being handled.
    def timed_out?(error)
      wrapped = error.respond_to?(:wrapped_exception) ? error.wrapped_exception : nil

      [wrapped, error.cause].any? { |inner| TIMEOUT_ERRORS.any? { inner.is_a?(it) } }
    end

    # +payload+ is the body as it is sent, and it is what the log reads as
    # well: see {#loggable_body}.
    def perform(method, path, query, payload, headers)
      # Built before the request is logged, so a rejected query or header does
      # not leave a line claiming a request that was never made.
      params = query && Transport.stringify_query(query)
      fields = headers && Transport.stringify_headers(headers)
      # The query as it is sent, like the headers and the body. The one the
      # caller handed over was logged, redacted by key through its Hashes,
      # and what it held that converts to a Hash and is sent as one - see
      # {.stringify_query} - was printed by `inspect`, under whatever key
      # it sat.
      log_request(method, path, params, payload, fields)

      @connection.public_send(method, path) do |request|
        request.params.update(params) if params
        # One at a time rather than in bulk, so that every name goes through
        # Faraday's own case-insensitive writer and replaces the header it
        # names rather than sitting beside it under another spelling.
        fields&.each { |name, value| request.headers[name] = value }
        request.body = payload if payload
        request.headers['From'] = on_behalf_of if on_behalf_of
      end
    end

    def build_connection
      connection = Faraday.new(
        url:     config.url,
        proxy:   config.proxy,
        ssl:     { verify: config.ssl_verify },
        # The encoder is this gem's own: see {QueryEncoder} for the one
        # structure Faraday's writes so that Rails reads another.
        request: { timeout: config.timeout, open_timeout: config.open_timeout, params_encoder: QueryEncoder },
        headers: { 'User-Agent' => Transport.stripped(config.user_agent), 'Accept' => 'application/json' }
      ) do |faraday|
        apply_authentication(faraday)
        faraday.request :json
        faraday.request :retry, Transport.retry_options(config)
        # Last in the stack, so a caller's middleware sees the request as this
        # gem finished building it and the response before anything else does.
        apply_middleware_and_adapter(faraday)
      end

      refuse_unusable_middleware!(connection)
      connection
    rescue ZammadAPI::Error
      raise
    rescue => e
      # An unregistered adapter, a proxy that is not a URL, or a middleware
      # that rejects its options is a configuration mistake, and neither
      # Faraday nor URI is part of this gem's surface.
      #
      # Caught as StandardError rather than as Faraday::Error, because the
      # failures that do not come from Faraday are the ones a caller is least
      # equipped to place: `proxy: 'http://user:pa ss@host'` escaped as
      # URI::InvalidURIError and a `middleware` callable that raises escaped
      # as whatever it raised, both straight past the
      # `rescue ZammadAPI::ConfigurationError` that building a client is
      # documented to need. The class is named in the message because
      # "bad URI (is not URI?)" on its own says nothing about where to look.
      raise ConfigurationError, "config could not be used to build a connection: #{e.class}: #{redact_config_values(e.message)}", cause: reportable_cause(e)
    end

    # Runs the caller's `middleware:` callable, and then settles the adapter.
    #
    # The adapter used to be set after the callable, unconditionally, and
    # setting one replaces the one that is there. So an adapter the callable
    # chose was dropped without a word: `middleware: ->(f) { f.adapter
    # :test, stubs }` left the connection on Net::HTTP, and a test that
    # believed itself stubbed sent real requests with the real token. The
    # callable is also the one place an adapter can be given arguments -
    # `f.adapter :net_http_persistent, pool_size: 5` - since `adapter:`
    # takes a name.
    #
    # An adapter the callable set is kept. Whether it set one is asked of
    # the handler's identity: Faraday puts its default in before the block
    # runs and builds a new handler for every `adapter` call, so one that
    # names the default again, to hand it a block, is seen as well.
    #
    # Named in both places, it is refused. One of the two would be dropped,
    # and which one is not something either spelling says.
    def apply_middleware_and_adapter(faraday)
      preset = faraday.builder.adapter
      config.middleware&.call(faraday)
      chosen = faraday.builder.adapter

      return faraday.adapter(config.adapter || Faraday.default_adapter) if chosen.equal?(preset)
      return if config.adapter.nil?

      raise ConfigurationError,
            "config adapter is #{config.adapter.inspect}, and the `middleware:` callable set an adapter as well (#{chosen.name}): " \
            'a connection has one adapter. Drop the `adapter:` option to use the one the callable sets, with the arguments ' \
            'it gives it, or drop the call from the callable.'
    end

    # The error to keep as the cause of the ConfigurationError above, where
    # it can be kept.
    #
    # Ruby attaches the error being rescued to the one raised in its place,
    # and a report prints the whole chain: `full_message`, a logger's
    # formatter, an error tracker. So the message above was scrubbed and the
    # original went out right behind it, `caused by URI::InvalidURIError: bad
    # URI (is not URI?): "http://user:pa ss@host:3128"`, password and all.
    #
    # Dropped only where that is what would happen. The whole report is
    # asked, causes of its own included, because the whole report is what
    # gets printed, and it is asked the question the message was: whether it
    # quotes a configured value that redaction changes. Every other failure
    # keeps its cause. A `middleware:` callable that raises is a bug in the
    # caller's own code, and the backtrace into it is the one thing the
    # message cannot carry.
    #
    # An error that cannot render its report is dropped as well. Rendering is
    # the error's own code - `detailed_message` is there to be overridden,
    # and one written without the `highlight:` keyword raises ArgumentError
    # from inside `full_message` - and this runs in the rescue above, so what
    # it raised left in place of the ConfigurationError, past the rescue
    # building a client is documented to need. A report that cannot be read
    # cannot be shown to quote nothing, which is the one condition a cause is
    # kept on.
    def reportable_cause(error)
      report = error.full_message(highlight: false)

      redact_config_values(report) == report ? error : nil
    rescue
      nil
    end

    # The underlying error quotes the value it rejected, and for a proxy that
    # value carries its credentials: `proxy: 'http://user:pa ss@host:3128'`
    # came back as URI::InvalidURIError with the whole URL, password included,
    # in its message - and that message goes into the ConfigurationError
    # above, which lands in every log and exception report. The one case
    # {Config#inspect} and {Config#redacted} exist to prevent, reached by
    # another route.
    #
    # The configured values are swapped for their redacted forms rather than
    # the message being dropped, because "bad URI (is not URI?)" without the
    # URI says nothing about where to look. Substring replacement, because
    # the message embeds the value verbatim, and the url as well as the proxy
    # because {Config} can only refuse the credentials in a url it can read:
    # one that is not a URL at all gets this far, and is quoted here.
    def redact_config_values(message)
      [config.proxy, config.url].compact.inject(message.to_s) do |text, value|
        redacted = config.redacted(value)

        # The block form. A String replacement expands the backslash
        # sequences it contains, and the replacement here is the configured
        # value with its userinfo blanked - so a value carrying `\0` or `\&`
        # put the whole matched text back, credentials included, into the
        # message it had just been taken out of, and one carrying `\1` cut
        # the replacement short instead.
        #
        # Every spelling of the value, because the error being quoted may
        # have inspected it rather than interpolated it: URI::InvalidURIError
        # does, and inspect escapes exactly the backslashes, quotes and
        # control characters that make a URL invalid in the first place. The
        # escaped text no longer equals the value as configured, so the swap
        # matched nothing and left the password standing in full - the case
        # this method exists for, reached through the quoting rather than
        # the value.
        quoted_spellings(value).inject(text) { |scrubbed, spelling| scrubbed.gsub(spelling) { redacted } }
      end
    end

    # The value as an error may have quoted it: as it is, as +inspect+
    # writes it, and as +dump+ does.
    #
    # The last two part ways at the first character outside ASCII, which
    # +inspect+ leaves standing and +dump+ writes as an escape, and URI
    # rejects a URL holding one with the +dump+ spelling: "URI must be ascii
    # only" and the value with every such character as `\u00E4`. A password
    # with an umlaut in it therefore matched neither of the two spellings
    # that were looked for, and stayed in the message - and in the cause,
    # which is kept wherever redaction finds nothing to change.
    def quoted_spellings(value) = [value, value.inspect[1...-1], value.dump[1...-1]].compact.uniq

    # A token as every adapter is to be handed it: see {Transport.stripped}.
    # A user and password are sent Base64-encoded, whatever is around them.
    def apply_authentication(faraday)
      case config.authentication_scheme
      when :http_token   then faraday.request :authorization, 'Token', Transport.stripped(config.http_token.to_s)
      when :oauth2_token then faraday.request :authorization, 'Bearer', Transport.stripped(config.oauth2_token.to_s)
      else                    faraday.request :authorization, :basic, config.user, config.password
      end
    end

    # The header values as text, as well as the names. Faraday keeps a value
    # as whatever wrote it: faraday-gzip sets Content-Length to the Integer
    # length of what it inflated, and {#missing_bytes} asked a regexp of that,
    # so every 2xx behind such a middleware raised a bare TypeError.
    def decode(faraday_response)
      headers    = faraday_response.headers.to_h.to_h { |name, value| [name.to_s.downcase, value.to_s] }.freeze
      raw_body   = raw_body!(faraday_response.body)
      body, json = Response.decode_body(headers['content-type'], raw_body)

      Response.new(
        status:   faraday_response.status,
        headers:  headers,
        body:     body,
        raw_body: raw_body,
        json:     json
      )
    end

    # Middleware this gem cannot do its own work behind, each with what it
    # takes away and how it is usually spelled. Matched by name so that naming
    # one does not require it to be loaded, and looked for among the ancestors
    # of what is in the stack: see {#refused_middleware}.
    #
    # The first reads the body before this gem can. The second raises for a
    # 4xx or 5xx before this gem sees the response, and it sits below the
    # retry middleware, which is where a caller's middleware goes: a GET
    # answered 503 left as Faraday::ServerError without being retried, a 404
    # as Faraday::ResourceNotFound, so `exists?` raised for a record that is
    # merely absent, and a 422 as an error `save` does not turn into false.
    # None of them is a {ZammadAPI::Error}, which is what every failure is
    # documented to leave as.
    REFUSED_MIDDLEWARE = {
      'Faraday::Response::Json'       => ['which decodes the response body before this gem can. This gem parses JSON itself, and hands ' \
                                          'the undecoded bytes to attachment downloads, so it needs the body as it arrives',
                                          'c.response :json'].freeze,
      'Faraday::Response::RaiseError' => ['which raises a Faraday error for a 4xx or 5xx response before this gem sees it. This gem ' \
                                          'raises its own error for each status, and retries a read that was answered 429 or 5xx, ' \
                                          'and behind this middleware it does neither',
                                          'c.response :raise_error'].freeze
    }.freeze
    private_constant :REFUSED_MIDDLEWARE

    # Refuses a stack this gem cannot work behind, while the stack is still
    # the only thing that has happened.
    #
    # `raw_body!` below catches a decoded body too, but only once a response
    # is in hand - which is one request too late: `client.groups.create(...)`
    # sent the POST, Zammad created the group, and only then did a
    # ConfigurationError come back, so a caller retrying what looked like a
    # configuration failure created a second one. The middleware is fully
    # visible here, where the unregistered adapter and the unusable proxy are
    # already refused before anything is sent.
    def refuse_unusable_middleware!(connection)
      connection.builder.handlers.each do |handler|
        refused = refused_middleware(handler.klass)
        raise ConfigurationError, refused_middleware_message(handler.klass, refused) if refused
      end
    end

    # Which refused middleware a class in the stack is, if it is one: itself,
    # or the one it inherits from.
    #
    # Only the class's own name used to be asked, and a subclass has another.
    # `class QuietRaiseError < Faraday::Response::RaiseError`, the usual way
    # to adjust what that middleware raises, went through `c.use` unrefused,
    # and its inherited handler then raised Faraday::ResourceNotFound for a
    # 404 before this gem saw the response - everything the refusal is there
    # to prevent, one `<` away from it.
    #
    # @return [String, nil] the name it is refused under
    def refused_middleware(klass) = klass.ancestors.filter_map(&:name).find { REFUSED_MIDDLEWARE.key?(it) }

    # A subclass is named along with what it inherits from, because the
    # reason describes the parent - and it is told to drop "it", because the
    # line that added a subclass is not the one the parent is usually spelled
    # with.
    def refused_middleware_message(klass, refused)
      reason, spelling = REFUSED_MIDDLEWARE.fetch(refused)
      found, drop      = klass.name == refused ? [refused, "`#{spelling}`"] : ["#{klass.name || 'an anonymous class'}, a subclass of #{refused}", 'it']

      "the configured middleware includes #{found}, #{reason}: drop #{drop} from the `middleware:` callable."
    end

    # The body as it came off the wire.
    #
    # `middleware:` is a documented seam and `c.response :json` is a
    # reasonable thing to put through it, at which point Faraday hands over a
    # Hash rather than the bytes. `to_s` turned that into a Ruby inspect
    # string, which JSON.parse then refused, so every record built from the
    # response died in {Response#decoded} with a ParseError naming Zammad for
    # what the caller's own stack had done.
    #
    # A backstop rather than the first line of defence: the stack is checked
    # when it is built, which catches `c.response :json` before a request goes
    # out. This is what is left for a middleware that decodes without being one
    # of the names that check knows.
    #
    # Said plainly instead. Re-encoding the parsed structure was the other
    # way out, and it is worse than it looks: {Response#raw_body} is
    # documented as the undecoded body and
    # {Resources::TicketArticleAttachment#download} hands exactly those bytes
    # back as the file, so a re-encoding silently returns something that is
    # not what Zammad stored - and JSON.generate has its own failures, which
    # would escape from here past the `rescue ZammadAPI::Error` every caller
    # is told to write. Once the bytes are gone they cannot be recovered, so
    # the honest answer is to name the cause while it is still visible.
    def raw_body!(body)
      return body.to_s if body.nil? || body.is_a?(String)

      raise ConfigurationError,
            'the configured middleware decoded the response body before this gem could ' \
            "(Faraday handed over #{body.class} rather than the raw body). This gem parses JSON itself, " \
            'and hands the undecoded bytes to attachment downloads, so it needs the body as it arrived: ' \
            'drop the parsing middleware - `c.response :json` is the usual one - from the `middleware:` callable.'
    end

    def log_request(method, path, query, payload, headers)
      logger.debug do
        "Zammad API request: #{method.to_s.upcase} #{Transport.redact_path(path)}#{" query=#{Transport.redact(query).inspect}" if query}#{" headers=#{Transport.redact(headers).inspect}" if headers}"
      end
      logger.debug { "Zammad API payload: #{loggable_body(payload).inspect}" } if payload
    end

    def log_response(method, path, response, started)
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      logger.debug { "Zammad API response: #{method.to_s.upcase} #{Transport.redact_path(path)} -> #{response.status} in #{duration}ms" }
    end

    # What the log prints for a request body: the body as it is sent, read
    # back for its keys and redacted by them.
    #
    # Read from the encoded payload and not from what the caller handed
    # over, because {.redact} works by key and only a Hash has keys. What
    # was handed over was printed by +inspect+ wherever it was anything
    # else, and there are two ways for that to be a credential.
    #
    # One is a String, which is the caller's own encoding:
    # `client.post(path, body: '{"login":"a","password":"hunter2"}')` was
    # written to the log as it stood.
    #
    # The other is an object inside the body. One that writes its own JSON
    # goes out as keys and values like any Hash - a value object with a
    # +to_json+, as the whole body or under a key of it - and +inspect+
    # printed every one of them. So does one that is sent as its +as_json+:
    # see {.json_object}.
    #
    # So the payload is parsed, and the log holds what the wire holds. Where
    # it is a JSON object or array it is redacted like the structure it
    # spells. Where it is not - a form body, a file, a single value -
    # nothing in it can be told from a credential, and its size is logged
    # in its place. Parsed only where the line is written: this runs inside
    # the logger's block.
    def loggable_body(payload)
      decoded = JSON.parse(payload)
      decoded.is_a?(Hash) || decoded.is_a?(Array) ? Transport.redact(decoded) : unlogged_body(payload)
    rescue JSON::JSONError, EncodingError
      unlogged_body(payload)
    end

    def unlogged_body(body) = "[#{body.bytesize} bytes that are not a JSON object or array, not logged]"

    def logger = config.logger
  end
end
