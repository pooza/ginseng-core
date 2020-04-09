require 'httparty'
require 'rest-client'

module Ginseng
  class HTTP
    include Package
    attr_reader :base_uri

    def initialize
      ENV['SSL_CERT_FILE'] ||= File.join(Environment.dir, 'cert/cacert.pem')
    end

    def base_uri=(uri)
      unless uri.nil?
        uri = Ginseng::URI.parse(uri.to_s) unless uri.is_a?(Ginseng::URI)
        raise 'Invalid base_uri' unless uri.absolute?
      end
      @base_uri = uri
    end

    def create_uri(uri)
      return uri if uri.is_a?(URI)
      uri = URI.parse(uri.to_s)
      return uri if uri.absolute?
      raise 'base_uri undefined' unless @base_uri
      uri.scheme = @base_uri.scheme
      uri.host = @base_uri.host
      uri.port = @base_uri.port
      return uri
    end

    def get(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      return HTTParty.get(create_uri(uri).normalize, options)
    end

    def post(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      options[:headers]['Content-Type'] ||= 'application/json'
      return HTTParty.post(create_uri(uri).normalize, options)
    end

    def delete(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      options[:headers]['Content-Type'] ||= 'application/json'
      return HTTParty.delete(create_uri(uri).normalize, options)
    end

    def upload(uri, file, headers = {}, body = {})
      file = File.new(file, 'rb') unless file.is_a?(File)
      headers['User-Agent'] ||= user_agent
      body[:file] = file
      return RestClient.post(create_uri(uri).normalize.to_s, body, headers)
    end

    def user_agent
      return package_class.user_agent
    end
  end
end
