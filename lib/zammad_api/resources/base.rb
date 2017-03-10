require 'cgi'
require 'json'
require 'zammad_api/transport'

module ZammadAPI
  module Resources
    class Base
      attr_accessor :new_instance, :url, :attributes
      attr_reader :changes

      def initialize(transport, attributes = {})
        @new_instance = true
        @transport    = transport
        @changes      = {}
        @url          = self.class.get_url

        if attributes.nil?
          attributes = {}
        end
        @attributes = attributes
        symbolize_keys_deep!(@attributes)
      end

      def method_missing(method, *args)
        return @attributes[method] if !method.to_s.end_with?('=')
        method              = method.to_s[0, method.length - 1].to_sym
        @changes[method]    = [@attributes[method], args[0]]
        @attributes[method] = args[0]
        nil
      end

      def new_record?
        @new_instance
      end

      def changed?
        @changes.present?
      end

      def destroy
        response = @transport.delete(url: "#{@url}/#{@attributes[:id]}")
        if response.body.to_s != '' && response.body.to_s != ' '
          data = JSON.parse(response.body)
        end
        return true if response.status == 200
        raise "Can't destroy object (#{self.class.name}): #{data['error']}"
      end

      def save
        attributes = saved_attributes
        symbolize_keys_deep!(attributes)
        attributes.delete(:article)
        @attributes   = attributes
        @new_instance = false
        @changes      = {}
        true
      end

      def self.get_url
        @url
      end

      def self.url(value)
        @url = value
      end

      def self.all(transport, _)
        ZammadAPI::ListAll.new(self, transport, per_page: 100)
      end

      def self.search(transport, parameter)
        ZammadAPI::ListSearch.new(self, transport, parameter)
      end

      def self.find(transport, id)
        response = transport.get(url: "#{@url}/#{id}?expand=true")
        data = JSON.parse(response.body)
        if response.status != 200
          raise "Can't find object (#{self.class.name}): #{data['error']}"
        end
        item = new(transport, data)
        item.new_instance = false
        item
      end

      def self.create(transport, data)
        item = new(transport, data)
        item.save
        item
      end

      def self.destroy(transport, id)
        item = find(transport, id)
        item.destroy
        true
      end

      private

      def saved_attributes
        return save_new if @new_instance
        save_existing
      end

      def save_new
        response   = @transport.post(url: "#{@url}?expand=true", params: @attributes)
        attributes = JSON.parse(response.body)
        return attributes if response.status == 201
        save_error(attributes)
      end

      def save_existing
        attributes_to_post = {}
        @changes.each { |name, values|
          attributes_to_post[name] = values[1]
        }
        response   = @transport.put(url: "#{@url}/#{@attributes[:id]}?expand=true", params: attributes_to_post)
        attributes = JSON.parse(response.body)

        return attributes if response.status == 200
        save_error(attributes)
      end

      def save_error(attributes)
        raise "Can't save object (#{self.class.name}): #{attributes['error']}"
      end

      def symbolize_keys_deep!(hash)
        hash.keys.each do |key|
          key_symbol       = key.respond_to?(:to_sym) ? key.to_sym : key
          hash[key_symbol] = hash.delete key # Preserve order even when key == key_symbol

          symbolize_keys_deep! hash[key_symbol] if hash[key_symbol].is_a? Hash
        end
      end
    end
  end
end
