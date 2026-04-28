require 'json'

module ZammadAPI
  module JsonHelper
    def safe_json_parse(string)
      JSON.parse(string)
    rescue JSON::ParserError
      {}
    end
  end
end
