require 'httparty'
require 'rest-client'

module Ginseng
  class HTTP
    include Package
    attr_reader :base_uri

    def initialize
      ENV['SSL_CERT_FILE'] ||= File.join(Environment.dir, 'cert/cacert.pem')
      @logger = logger_class.new
    end

    def base_uri=(uri)
      unless uri.nil?
        uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
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
      uri = create_uri(uri.to_s) unless uri.is_a?(URI)
      start = Time.now
      r = HTTParty.get(uri.normalize, options)
      log(method: 'GET', url: uri.to_s, status: r.code, start: start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    end

    def post(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      options[:headers]['Content-Type'] ||= 'application/json'
      if options[:headers]['Content-Type'] == 'application/json' && options[:body].is_a?(Hash)
        options[:body] = options.to_json
      end
      uri = create_uri(uri.to_s) unless uri.is_a?(URI)
      start = Time.now
      r = HTTParty.post(uri.normalize, options)
      log(method: 'POST', url: uri.to_s, status: r.code, start: start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    end

    def delete(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      options[:headers]['Content-Type'] ||= 'application/json'
      uri = create_uri(uri.to_s) unless uri.is_a?(URI)
      start = Time.now
      r = HTTParty.delete(uri.normalize, options)
      log(method: 'DELETE', url: uri.to_s, status: r.code, start: start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    end

    def upload(uri, file, headers = {}, body = {})
      file = File.new(file, 'rb') unless file.is_a?(File)
      headers['User-Agent'] ||= user_agent
      body[:file] = file
      uri = create_uri(uri.to_s) unless uri.is_a?(URI)
      start = Time.now
      r = RestClient.post(uri.normalize.to_s, body, headers)
      log(method: 'POST', type: 'multipart/form-data', url: uri.to_s, status: r.code, start: start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    end

    def user_agent
      return package_class.user_agent
    end

    private

    def log(message)
      message = {message: message.to_s} unless message.is_a?(Hash)
      if message[:start]
        message[:seconds] = (Time.now - message[:start]).round(3)
        message.delete(:start)
      end
      message[:class] = self.class.to_s
      @logger.info(message)
    rescue
      warn message.to_json
    end
  end
end
