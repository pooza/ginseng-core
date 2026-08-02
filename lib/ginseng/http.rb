# frozen_string_literal: true

require 'httparty'
require 'net/http'

module Ginseng
  class HTTP
    include Package

    attr_reader :base_uri
    attr_accessor :retry_limit

    # 4xx のうち、時間をおけば結果が変わりうるもの。
    RETRYABLE_STATUSES = [408, 425, 429].freeze

    # host_validator 使用時に追うリダイレクトの上限。
    MAX_REDIRECTS = 8

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

    # options[:host_validator] に「ホスト名を受けて真偽値を返す callable」を渡すと、
    # リダイレクトを自前で追い、**各ホップのホストを検証**する。
    #
    # HTTParty は既定でリダイレクトを追従するため、呼び出し側で初段のホストだけ
    # 検証しても、リダイレクト先は素通りになり "見せかけの安全" にしかならない
    # (mulukhiya-toot-proxy#4410)。かといって follow_redirects: false で一律に
    # 追従を切ると、正規に 302 を返す相手（Google Apps Script 等）が壊れる。
    def get(uri, options = {})
      options[:headers] ||= {}
      options[:headers]['User-Agent'] ||= user_agent
      if validator = options.delete(:host_validator)
        return get_validating_hops(create_uri(uri), options, validator)
      end
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

    def get_validating_hops(uri, options, validator)
      options = options.merge(follow_redirects: false)
      limit = options.delete(:max_redirects) || MAX_REDIRECTS
      (limit + 1).times do
        # 検証は repeat の外で行う。中に置くと、拒否した相手を retry_limit 回
        # 叩き直すうえ、GatewayError の再送判定にも巻き込まれる。
        validate_host!(uri, validator)
        response = repeat(:get, uri, start = Time.now) do
          r = HTTParty.get(uri.normalize, options)
          log(method: :get, url: uri, status: r.code, start:)
          raise GatewayError, "Bad response #{r.code}" unless r.code < 400
          r
        end
        location = redirect_location(response)
        return response unless location
        uri = create_uri(::URI.join(uri.to_s, location).to_s)
      end
      raise GatewayError, "Too many redirects (#{limit})"
    end

    def redirect_location(response)
      return nil unless response.code.between?(300, 399)
      location = response.headers['location']
      return nil unless location.present?
      return location
    end

    def validate_host!(uri, validator)
      return if validator.call(uri.host)
      raise GatewayError, "Rejected host '#{uri.host}'"
    end

    def repeat(method, uri, start)
      cnt ||= 0
      yield
    rescue Net::ReadTimeout => e
      log_retry_error(e, method, uri, start)
      raise GatewayError, e.message, e.backtrace
    rescue => e
      cnt += 1
      log_retry_error(e, method, uri, start, count: cnt)
      raise GatewayError, e.message, e.backtrace unless retryable?(e) && cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    # 再送して結果が変わりうるか。
    #
    # ⚠ **恒久的な失敗を再送しない。** 401 / 403 / 422 を投げ直しても結果は同じで、
    # 待ち時間と相手への負荷とエラーログだけが retry_limit 倍になる。
    # 408（タイムアウト）/ 425（Too Early）/ 429（レート制限）は時間をおけば
    # 通るので再送する。ステータスを取り出せない失敗（接続断など）も再送する。
    #
    # 方針を変えたいアプリはこのメソッドを override する。
    def retryable?(error)
      return true unless error.is_a?(GatewayError)
      status = error.source_status
      return true if RETRYABLE_STATUSES.include?(status)
      return status >= 500
    end

    def log_retry_error(error, method, uri, start, count: nil)
      @logger.error(
        error:,
        method: method.upcase.to_sym,
        url: uri.to_s,
        start:,
        count:,
      )
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
