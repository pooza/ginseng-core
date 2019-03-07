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
      return HTTParty.get(uri, options)
    rescue => e
      raise GatewayError, e.message
    end

    def post(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      options[:headers]['Content-Type'] ||= 'application/json'
      return HTTParty.post(uri, options)
    rescue => e
      raise GatewayError, e.message
    end

    def upload(uri, file, headers = {})
      file = File.new(file, 'rb') unless file.is_a?(File)
      headers['User-Agent'] ||= user_agent
      return RestClient.post(uri.to_s, {file: file}, headers)
    rescue => e
      raise GatewayError, e.message
    end

    def user_agent
      return package_class.constantize.user_agent
    end
  end
end
