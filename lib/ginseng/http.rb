# frozen_string_literal: true

require 'httparty'
require 'net/http'

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

    def head(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      repeat(:get, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.head(uri.normalize, options)
        log(method: :head, url: uri, status: response.code, start:)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        return response
      end
    end

    def get(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      repeat(:get, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.get(uri.normalize, options)
        log(method: :get, url: uri, status: response.code, start:)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        return response
      end
    end

    def post(uri, options = {})
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      repeat(:post, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.post(uri.normalize, options)
        log(method: :post, url: uri, status: response.code, start:)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        return response
      end
    end

    def delete(uri, options = {})
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      repeat(:delete, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.delete(uri.normalize, options)
        log(method: :post, url: uri, status: response.code, start:)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        return response
      end
    end

    def put(uri, options = {})
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      repeat(:delete, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.put(uri.normalize, options)
        log(method: :put, url: uri, status: response.code, start:)
        raise GatewayError, "Bad response #{response.code}" unless response.code < 400
        return response
      end
    end

    def mkcol(uri, options = {})
      repeat(:mkcol, uri = create_uri(uri), start = Time.now) do
        net_uri = ::URI.parse(uri.normalize.to_s)
        http = Net::HTTP.new(net_uri.host, net_uri.port)
        http.use_ssl = net_uri.scheme == 'https'
        request = Net::HTTP::Mkcol.new(net_uri.request_uri)
        create_headers(options[:headers]).each {|k, v| request[k] = v}
        response = http.request(request)
        code = response.code.to_i
        log(method: :mkcol, url: uri, status: code, start:)
        raise GatewayError, "Bad response #{code}" unless code < 400
        return response
      end
    end

    def upload(uri, file, options = {})
      return File.open(file, 'rb') {|f| upload(uri, f, options)} if file.is_a?(String)
      uri = create_uri(uri)
      headers = options[:headers] || {}
      headers['User-Agent'] ||= user_agent
      body = options[:payload] || options[:body] || {}
      body[:file] = file if file
      method = options[:method] || :post
      start = Time.now
      response = HTTParty.public_send(method, uri.normalize, {
        headers:,
        body:,
        multipart: true,
        timeout: @config['/http/timeout/seconds'],
      })
      log(method:, multipart: true, url: uri, status: response.code, start:)
      raise GatewayError, "Bad response #{response.code}" unless response.code < 400
      return response
    end

    private

    def repeat(method, uri, start)
      cnt ||= 0
      yield
    rescue => e
      cnt += 1
      @logger.error(
        error: e,
        method: method.upcase.to_sym,
        url: uri.to_s,
        start:,
        count: cnt,
      )
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
