require 'cgi'
require 'json'
require 'zammad_api/transport'

module ZammadAPI
  module Resources
    class Base
      attr_accessor :new_instance, :url, :attributes

      def initialize(transport, attributes)
        @new_instance = true
        @transport = transport
        if attributes.nil?
          attributes = {}
        end
        @attributes = attributes
        @changes = {}
        symbolize_keys_deep!(@attributes)
        @url = self.class.url_get
      end

      def method_missing(method, *args)
        if method.to_s[-1, 1] == '='
          method = method.to_s[0, method.length - 1].to_sym
          @changes[method] = [@attributes[method], args[0]]
          @attributes[method] = args[0]
        end
        @attributes[method]
      end

      def new_record?
        @new_instance
      end

      attr_reader :changes

      def changed?
        return false if @changes.empty?
        true
      end

      def destroy
        response = @transport.delete(url: "#{@url}/#{@attributes[:id]}")
        if response.body.to_s != '' && response.body.to_s != ' '
          data = JSON.parse(response.body)
        end
        if response.status != 200
          raise "Can't destroy object (#{self.class.name}): #{data['error']}"
        end
        true
      end

      def save
        if @new_instance
          @attributes[:expand] = true
          response = @transport.post(url: @url, params: @attributes)
          attributes = JSON.parse(response.body)
          if response.status != 201
            raise "Can't create new object (#{self.class.name}): #{attributes['error']}"
          end
        else
          attributes_to_post = { expand: true }
          @changes.each {|name, values|
            attributes_to_post[name] = values[1]
          }
          response = @transport.put(url: "#{@url}/#{@attributes[:id]}", params: attributes_to_post)
          attributes = JSON.parse(response.body)
          if response.status != 200
            raise "Can't update new object (#{self.class.name}): #{attributes['error']}"
          end
        end
        symbolize_keys_deep!(attributes)
        attributes.delete(:article)
        @attributes = attributes
        @new_instance = false
        @changes = {}
        true
      end

      def self.url_get
        @url
      end

      def self.url(value)
        @url = value
      end

      def self.all_fetch(transport, _data, page_number = nil, per_page_number = 100)
        url = "#{@url}?expand=true"
        if page_number && per_page_number
          url += "&page=#{page_number}&per_page=#{per_page_number}"
        end
        response = transport.get(url: url)
        data = JSON.parse(response.body)
        if response.status != 200
          raise "Can't get .all of object (#{self.class.name}): #{data['error']}"
        end
        #record_ids: item_ids,
        #assets: assets,
        list = []
        data.each {|local_data|
          item = new(transport, local_data)
          item.new_instance = false
          list.push item
        }
        list
      end

      def self.search_fetch(transport, data, page_number = nil, per_page_number = 100)
        url = "#{@url}/search?expand=true&term=#{CGI.escape data[:query]}"
        if page_number
          url += "&page=#{page_number}&per_page=#{per_page_number}"
        end
        response = transport.get(url: url)
        data = JSON.parse(response.body)
        if response.status != 200
          raise "Can't get .search of object (#{self.class.name}): #{data['error']}"
        end
        #record_ids: item_ids,
        #assets: assets,
        list = []
        data.each {|local_data|
          item = new(transport, local_data)
          item.new_instance = false
          list.push item
        }
        list
      end

      def self.all(transport, _data)
        ZammadAPI::ListAll.new(transport, self)
      end

      def self.search(transport, data)
        ZammadAPI::ListSearch.new(transport, self, data)
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

      def symbolize_keys_deep!(h)
        h.keys.each do |k|
          ks    = k.respond_to?(:to_sym) ? k.to_sym : k
          h[ks] = h.delete k # Preserve order even when k == ks
          symbolize_keys_deep! h[ks] if h[ks].is_a? Hash
        end
      end

    end

  end

end
