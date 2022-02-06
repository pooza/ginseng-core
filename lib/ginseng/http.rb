require 'httparty'
require 'rest-client'

module Ginseng
  class HTTP
    include Package
    attr_reader :base_uri
    attr_accessor :retry_limit

    def initialize
      ENV['SSL_CERT_FILE'] ||= Environment.cert_file
      @logger = logger_class.new
      @config = config_class.instance
      @retry_limit = @config['/http/retry/limit']
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
      response = HTTParty.get(uri.normalize, options)
      log(method: :get, url: uri, status: response.code, start: start)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    rescue => e
      cnt += 1
      @logger.error(error: e, method: :get, url: uri.to_s, count: cnt)
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
      response = HTTParty.post(uri.normalize, options)
      log(method: :post, url: uri, status: response.code, start: start)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    rescue => e
      cnt += 1
      @logger.error(error: e, method: :post, url: uri.to_s, count: cnt)
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
      response = HTTParty.delete(uri.normalize, options)
      log(method: :delete, url: uri, status: response.code, start: start)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    rescue => e
      cnt += 1
      @logger.error(error: e, method: :delete, url: uri.to_s, count: cnt)
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    def put(uri, options = {})
      cnt ||= 0
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      uri = create_uri(uri)
      start = Time.now
      response = HTTParty.put(uri.normalize, options)
      log(method: :delete, url: uri, status: response.code, start: start)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    rescue => e
      cnt += 1
      @logger.error(error: e, method: :put, url: uri.to_s, count: cnt)
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    def upload(uri, file, headers = {}, payload = {}, options = {})
      file = File.new(file, 'rb') unless file.is_a?(File)
      headers['User-Agent'] ||= user_agent
      uri = create_uri(uri)
      start = Time.now
      response = RestClient.post(uri.normalize.to_s, payload.merge(file: file), headers)
      log(method: :post, multipart: true, url: uri, status: response.code, start: start)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    end

    private

    def user_agent
      return package_class.user_agent
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
      message.deep_symbolize_keys! if message.is_a?(Hash)
      message ||= {message: message.to_s}
      if message[:start]
        message[:seconds] = (Time.now - message[:start]).round(3)
        message.delete(:start)
      end
      message[:method] = message[:method].upcase.to_sym if message[:method]
      message[:url] = message[:url].to_s if message[:url]
      @logger.info(message)
    rescue
      warn message.to_json
    end
  end
end
