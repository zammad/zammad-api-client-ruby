# frozen_string_literal: true

# The Zammad the live checks run against: the integration specs, `rake spec`,
# `rake check_connection` and script/check_connection.rb.
#
# Each of them creates and deletes records, so none has a default for where,
# and each asks here whether one was named, so that they agree on it.
#
# Plain Ruby with nothing required, so that the check script, which loads
# nothing of the spec suite on purpose, can load it too.
module LiveTarget
  # What to write where TEST_URL is not set. A placeholder that cannot reach
  # anything if it is pasted as it is: `.example` is reserved and never
  # resolves, where `http://localhost:3000/` is a Zammad under development.
  EXAMPLE = 'TEST_URL=https://zammad.example/ TEST_USER=admin@example.com TEST_PASSWORD=test'

  module_function

  # @return [String, nil] TEST_URL, or nil where it is unset or blank -
  #   Unicode spaces included, as Rails reads blank
  def url
    value = ENV['TEST_URL'].to_s
    value.match?(/\A[[:space:]]*\z/) ? nil : value.strip
  end

  # @param what [String] what the refusing check would have done, and to what
  # @return [String]
  def unset_message(what)
    "TEST_URL is not set. #{what} creates and deletes records in the Zammad it runs against, so name one, " \
      "and make it one you can lose: #{EXAMPLE}"
  end
end
