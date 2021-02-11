require 'httparty'
require 'rest-client'
require 'facets/time'

module Ginseng
  class HTTP
    include Package
    attr_reader :base_uri

    def initialize
      ENV['SSL_CERT_FILE'] ||= Environment.cert_file
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
      response = nil
      secs = Time.elapse {response = HTTParty.get(uri.normalize, options)}
      log(method: 'GET', url: uri, status: response.code, seconds: secs.round(3))
      raise GatewayError, "Bad response #{r.code}" unless response.code < 400
      return response
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
      response = nil
      secs = Time.elapse {response = HTTParty.post(uri.normalize, options)}
      log(method: 'POST', url: uri, status: response.code, seconds: secs.round(3))
      raise GatewayError, "Bad response #{r.code}" unless response.code < 400
      return response
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
      response = nil
      secs = Time.elapse {response = HTTParty.delete(uri.normalize, options)}
      log(method: 'DELETE', url: uri, status: response.code, seconds: secs.round(3))
      raise GatewayError, "Bad response #{r.code}" unless response.code < 400
      return response
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
      response = nil
      secs = Time.elapse {response = RestClient.post(uri.normalize.to_s, body, headers)}
      log(method: 'POST', multipart: true, url: uri, status: response.code, seconds: secs.round(3))
      raise GatewayError, "Bad response #{r.code}" unless response.code < 400
      return response
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
      message[:url] = message[:url].to_s if message[:url]
      @logger.info(message)
    rescue
      warn message.to_json
    end
  end
end
