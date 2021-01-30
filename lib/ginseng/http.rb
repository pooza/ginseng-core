require 'httparty'
require 'rest-client'

module Ginseng
  class HTTP
    include Package
    attr_reader :base_uri

    def initialize
      ENV['SSL_CERT_FILE'] ||= File.join(Environment.dir, 'cert/cacert.pem')
      @logger = logger_class.new
      @config = config_class.instance
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
      cnt ||= 0
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      uri = create_uri(uri)
      start = Time.now
      r = HTTParty.get(uri.normalize, options)
      log(method: 'GET', url: uri.to_s, status: r.code, seconds: Time.now - start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    rescue => e
      cnt += 1
      @logger.error(error: e, count: cnt)
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    def post(uri, options = {})
      cnt ||= 0
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      uri = create_uri(uri)
      start = Time.now
      r = HTTParty.post(uri.normalize, options)
      log(method: 'POST', url: uri.to_s, status: r.code, seconds: Time.now - start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    rescue => e
      cnt += 1
      @logger.error(error: e, count: cnt)
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    def delete(uri, options = {})
      cnt ||= 0
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      uri = create_uri(uri)
      start = Time.now
      r = HTTParty.delete(uri.normalize, options)
      log(method: 'DELETE', url: uri.to_s, status: r.code, seconds: Time.now - start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    rescue => e
      cnt += 1
      @logger.error(error: e, count: cnt)
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    def upload(uri, file, headers = {}, body = {})
      cnt ||= 0
      file = File.new(file, 'rb') unless file.is_a?(File)
      headers['User-Agent'] ||= user_agent
      body[:file] = file
      uri = create_uri(uri)
      start = Time.now
      r = RestClient.post(uri.normalize.to_s, body, headers)
      log(method: 'POST', multipart: true, url: uri.to_s, status: r.code, seconds: Time.now - start)
      raise GatewayError, "Bad response #{r.code}" unless r.code < 400
      return r
    rescue => e
      cnt += 1
      @logger.error(error: e, count: cnt)
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    private

    def user_agent
      return package_class.user_agent
    end

    def retry_limit
      return @config['/http/retry/limit']
    end

    def retry_seconds
      return @config['/http/retry/seconds']
    end

    def create_headers(headers)
      headers ||= {}
      headers['User-Agent'] ||= user_agent
      headers['Content-Type'] ||= 'application/json'
      return headers
    end

    def create_body(body, headers)
      return body.to_json if headers['Content-Type'] == 'application/json' && body.is_a?(Hash)
      return body
    end

    def log(message)
      message = {message: message.to_s} unless message.is_a?(Hash)
      if message[:start]
        message[:seconds] = (Time.now - message[:start]).round(3)
        message.delete(:start)
      end
      @logger.info(message)
    rescue
      warn message.to_json
    end
  end
end
