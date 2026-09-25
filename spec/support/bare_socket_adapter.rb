# frozen_string_literal: true

require 'faraday'
require 'openssl'

# A Faraday adapter that lets a socket error out raw.
#
# Most adapters wrap one into Faraday::ConnectionFailed, but this gem lets a
# caller choose the adapter, and an adapter that does not wrap is the only way
# to tell apart the two halves of the retry configuration: which failures are
# mapped to a ZammadAPI error, and which are retried before being mapped.
class BareSocketAdapter < Faraday::Adapter
  class << self
    # @return [Array<Symbol>] the verb of every request that reached here
    attr_accessor :attempts
  end
  self.attempts = []

  def call(env)
    self.class.attempts << env.method
    raise Errno::ECONNRESET
  end
end

Faraday::Adapter.register_middleware(bare_socket: BareSocketAdapter)

# A Faraday adapter that lets a TLS failure out raw.
#
# The counterpart of BareSocketAdapter for OpenSSL::SSL::SSLError, which most
# adapters wrap into Faraday::SSLError. Unwrapped and unlisted, it escaped
# `request` entirely, past every `rescue ZammadAPI::Error` a caller had
# written.
class BareTlsAdapter < Faraday::Adapter
  class << self
    # @return [Array<Symbol>] the verb of every request that reached here
    attr_accessor :attempts
  end
  self.attempts = []

  def call(env)
    self.class.attempts << env.method
    raise OpenSSL::SSL::SSLError, 'certificate verify failed'
  end
end

Faraday::Adapter.register_middleware(bare_tls: BareTlsAdapter)
