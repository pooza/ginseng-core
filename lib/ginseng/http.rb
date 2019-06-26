require 'httparty'
require 'rest-client'

module Ginseng
  class HTTP
    include Package

    def initialize
      ENV['SSL_CERT_FILE'] ||= File.join(Environment.dir, 'cert/cacert.pem')
    end

    def get(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
      return HTTParty.get(uri.normalize, options)
    rescue => e
      raise GatewayError, e.message
    end

    def post(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      options[:headers]['Content-Type'] ||= 'application/json'
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
      return HTTParty.post(uri.normalize, options)
    rescue => e
      raise GatewayError, e.message
    end

    def upload(uri, file, headers = {})
      file = File.new(file, 'rb') unless file.is_a?(File)
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
      headers['User-Agent'] ||= user_agent
      return RestClient.post(uri.normalize.to_s, {file: file}, headers)
    rescue => e
      raise GatewayError, e.message
    end

    def user_agent
      return package_class.user_agent
    end
  end
end
