require 'httparty'
require 'rest-client'

module Ginseng
  class HTTP
    include Package
    include Mockable
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

    def head(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      repeat(:get, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.head(uri.normalize, options)
        log(method: :head, url: uri, status: response.code, start: start)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        save_mock(response, options)
        return response
      end
    rescue => e
      return load_mock(error: e, options: options)
    end

    def get(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      repeat(:get, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.get(uri.normalize, options)
        log(method: :get, url: uri, status: response.code, start: start)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        save_mock(response, options)
        return response
      end
    rescue => e
      return load_mock(error: e, options: options)
    end

    def post(uri, options = {})
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      repeat(:post, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.post(uri.normalize, options)
        log(method: :post, url: uri, status: response.code, start: start)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        save_mock(response, options)
        return response
      end
    rescue => e
      return load_mock(error: e, options: options)
    end

    def delete(uri, options = {})
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      repeat(:delete, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.delete(uri.normalize, options)
        log(method: :post, url: uri, status: response.code, start: start)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        save_mock(response, options)
        return response
      end
    rescue => e
      return load_mock(error: e, options: options)
    end

    def put(uri, options = {})
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      repeat(:delete, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.put(uri.normalize, options)
        log(method: :put, url: uri, status: response.code, start: start)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        save_mock(response, options)
        return response
      end
    rescue => e
      return load_mock(error: e, options: options)
    end

    def mkcol(uri, options = {})
      cnt ||= 0
      uri = create_uri(uri)
      start = Time.now
      response = RestClient::Request.execute(
        method: :mkcol,
        url: uri.normalize.to_s,
        headers: create_headers(options[:headers]),
      )
      log(method: :mkcol, url: uri, status: response.code, start: start)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    rescue => e
      cnt += 1
      @logger.error(error: e, method: :put, url: uri.to_s, count: cnt)
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    def upload(uri, file, options = {})
      file = File.new(file, 'rb') if file.is_a?(String)
      uri = create_uri(uri)
      headers = options[:headers] || {}
      headers['User-Agent'] ||= user_agent
      payload = options[:payload] || options[:body] || {}
      payload[:file] = file if file
      method = options[:method] || :post
      start = Time.now
      response = RestClient::Request.execute(
        method: method,
        url: uri.normalize.to_s,
        headers: headers,
        payload: payload,
      )
      log(method: method, multipart: true, url: uri, status: response.code, start: start)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    end

    private

    def repeat(method, uri, start)
      cnt ||= 0
      yield
    rescue => e
      @logger.error(error: e, method: method, url: uri.to_s, start: start, count: cnt)
      cnt += 1
      raise GatewayError, e.message, e.backtrace unless cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

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
