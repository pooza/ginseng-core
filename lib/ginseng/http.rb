# frozen_string_literal: true

require 'httparty'
require 'net/http'

module Ginseng
  class HTTP
    include Package
    include ByteLimitMethods
    include HostValidationMethods

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

    # サイズのプリフライト等で GET の前に HEAD を撃つ呼び出し側があり、GET だけを
    # 検証しても HEAD が素通りするなら SSRF 対策として意味を成さないので、head も
    # get と同じく options[:host_validator] を受ける (mulukhiya-toot-proxy#4523)。
    def head(uri, options = {})
      return request(:head, uri, options)
    end

    # options[:host_validator] に「ホスト名を受けて真偽値を返す callable」を渡すと、
    # リダイレクトを自前で追い、**各ホップのホストを検証**する。
    #
    # HTTParty は既定でリダイレクトを追従するため、呼び出し側で初段のホストだけ
    # 検証しても、リダイレクト先は素通りになり "見せかけの安全" にしかならない
    # (mulukhiya-toot-proxy#4410)。かといって follow_redirects: false で一律に
    # 追従を切ると、正規に 302 を返す相手（Google Apps Script 等）が壊れる。
    def get(uri, options = {})
      return request(:get, uri, options)
    end

    def post(uri, options = {})
      return request_with_body(:post, uri, options)
    end

    def delete(uri, options = {})
      return request_with_body(:delete, uri, options)
    end

    def put(uri, options = {})
      return request_with_body(:put, uri, options)
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
        bad_response!(response, code) unless code < 400
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
      bad_response!(response) unless response.code < 400
      return response
    end

    private

    # body を伴うメソッド（POST / DELETE / PUT）の共通経路。
    #
    # 括り出す前は delete が `method: :post` でログし、put が `repeat(:delete, ...)`
    # を呼んでいた（いずれもコピペ由来）。ここに寄せて解消している。
    def request_with_body(method, uri, options)
      options[:headers] = create_headers(options[:headers])
      options[:body] = create_body(options[:body], options[:headers])
      repeat(method, uri = create_uri(uri), start = Time.now) do
        response = HTTParty.public_send(method, uri.normalize, options)
        log(method:, url: uri, status: response.code, start:)
        bad_response!(response) unless response.code < 400
        return response
      end
    end

    # host_validator を持たない冪等メソッド（GET / HEAD）の共通経路。
    #
    # ⚠⚠ **呼び出し側の hash を壊さないこと (#528)。**以前はここで
    # `options.delete(:host_validator)` していたため、**同じ hash を head と get で
    # 使い回す呼び出しで、2 回目から validator が消えて無検証になっていた**。
    # それは `#head` のコメントがまさに勧めている「サイズのプリフライト」の形で、
    # **プリフライトを足したせいで本命の GET の検証が外れる**という裏返しだった
    # (mulukhiya-toot-proxy#4576 で実際に踏んだ)。
    #
    # ⚠ `headers` も複製する。`||=` と `[]=` は呼び出し側が渡した hash に
    # User-Agent を書き込んでしまう（次の要求へ持ち越される）。
    def request(method, uri, options)
      options = options.dup
      options[:headers] = (options[:headers] || {}).dup
      options[:headers]['User-Agent'] ||= user_agent
      max_bytes = options.delete(:max_bytes)
      if validator = options.delete(:host_validator)
        return request_validating_hops(method, create_uri(uri), options, validator, max_bytes)
      end
      repeat(method, uri = create_uri(uri), start = Time.now) do
        response = execute(method, uri, options, max_bytes)
        log(method:, url: uri, status: response.code, start:)
        bad_response!(response) unless response.code < 400
        return response
      end
    end

    def repeat(method, uri, start)
      cnt ||= 0
      yield
    rescue Net::ReadTimeout => e
      log_retry_error(e, method, uri, start)
      raise gateway_error(e)
    rescue => e
      cnt += 1
      log_retry_error(e, method, uri, start, count: cnt)
      raise gateway_error(e) unless retryable?(e) && cnt < retry_limit
      sleep(retry_seconds)
      retry
    end

    # 上流のレスポンスを添えて GatewayError を投げる。
    #
    # ⚠ message の書式は変えない。`source_status` の正規表現フォールバックや、
    # 呼び出し側の文字列マッチ (mulukhiya-toot-proxy の annict_service 等) が
    # これに依存している。**添えるだけ**にとどめる (mulukhiya-toot-proxy#4480)。
    def bad_response!(response, code = nil)
      error = GatewayError.new("Bad response #{code || response.code}")
      error.response = response
      raise error
    end

    # 既に GatewayError ならそのまま投げ直す。包み直すと response（上流ボディ）が
    # 落ちる (mulukhiya-toot-proxy#4480)。
    def gateway_error(error)
      return error if error.is_a?(GatewayError)
      wrapped = GatewayError.new(error.message)
      wrapped.set_backtrace(error.backtrace)
      return wrapped
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
      # ⚠ pinning できない = 設定の問題なので、試行の間に変わらない。既定では
      # source_status が 502 になり「上流の一時障害」として 5 回叩き直して
      # しまうため、ここで明示的に落とす。
      # ⚠ 上限超過 (TooLargeError) も同じ。相手が同じものを返す限り同じ場所で
      # 超えるだけで、再送のたびに上限ぶんの転送とメモリを食う (#526)。
      return false if error.is_a?(PinningError) || error.is_a?(TooLargeError)
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
