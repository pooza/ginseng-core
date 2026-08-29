# frozen_string_literal: true

require 'httparty'
require 'net/http'

module Ginseng
  class HTTP
    include Package
    include ByteLimitMethods
    include HostValidationMethods
    include RetryMethods

    attr_reader :base_uri
    attr_accessor :retry_limit

    # ⚠⚠ **`/http/timeout/seconds` を HTTParty へ渡すのはこの属性経由 (#514)。**
    # 渡していなかった間、get / post / put / delete の実効は **Net::HTTP 既定の
    # 60 秒**で、設定は upload にしか効いていなかった。無人で回るボットでは
    # 再送と掛け算になって滞留する（pooza/makoto2#90 で踏んだ）。
    # ⚠ 呼び出し側が `options[:timeout]` を明示したときは、そちらを優先する。
    attr_accessor :timeout

    # 4xx のうち、時間をおけば結果が変わりうるもの。
    RETRYABLE_STATUSES = [408, 425, 429].freeze

    # host_validator 使用時に追うリダイレクトの上限。
    MAX_REDIRECTS = 8

    # `Retry-After` として受け入れる上限（秒）。⚠ `/http/retry/max_seconds` で
    # 上書きできる。これを超える待ちを指定されたら、待たずに諦める (#525)。
    MAX_RETRY_SECONDS = 60

    def initialize
      # ⚠⚠ **自分（アプリ）の cert を見る (#548)。** ここで `Environment` と書くと
      # 字面どおり `Ginseng::Environment` ＝ **gem のルート**に解決される。利用アプリ
      # では `Package` が指す Environment（`Makoto::Environment` 等）が正しい。
      #
      # 🔴 直す前は、**利用アプリが「自分の `Gemfile.lock` が刺した gem リビジョン
      # に同梱された CA バンドル」を使っていた**（実測: makoto2 が 2026-07-30 の版）。
      # ⚠ `Gemfile.lock` を更新するまで古いままで、しかも誰にも見えない。
      #
      # ⚠ **無ければ立てない (#512)。** OS の CA ストアに倒れる。**固定したいなら
      # `rake cert:update` で自分の `cert/cacert.pem` を持つ** — そのほうが状態が
      # 見える。⚠ 同じ値を `ca_file` 相当へ直接渡す利用者
      # (mulukhiya-toot-proxy の Listener#root_cert_file) では、存在しないパスだと
      # `SSL_CTX_load_verify_file` が即座に SSLError で落ちる。
      #
      # ⚠ **立てたことを記録する (#556)。** `with_system_cert_store` が外してよいのは
      # **自分で立てた値だけ**で、運用者が渡した企業内 CA まで外すと TLS ごと壊れる。
      cert_file = environment_class.cert_file
      if ENV.fetch('SSL_CERT_FILE', nil).nil? && File.exist?(cert_file)
        ENV['SSL_CERT_FILE'] = cert_file
        Ginseng.managed_cert_file = cert_file
      end
      @logger = logger_class.new
      @config = config_class.instance
      @retry_limit = @config['/http/retry/limit']
      @timeout = @config['/http/timeout/seconds']
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
      method = options[:method] || :post
      hop_options = upload_options(file, options)
      # ⚠⚠ **ここも validator を黙って捨てていた (#569)。** 利用側は「あれは
      # version / filename を見るリクエストパラメータの hash だから」と解釈して
      # 自分で delete していた (mulukhiya-toot-proxy#4576) — **渡せてしまうのに
      # 効かない**ので、そう読むほかなかった。
      # ⚠ 307 / 308 で body を撃ち直すとき、multipart の IO は
      # `rewind_body!` が巻き戻す。
      # ⚠⚠ **ここは `delete` にしない（#578 の「ついでの所見」）。** `request_with_body`
      # が `delete` なのは**先に `options.dup` しているから**で、こちらは dup して
      # いない（`upload_options` が別の hash を組む）。⚠ 揃えようとして `delete` に
      # すると**呼び出し側の hash から validator が消える** — #528 で踏んだ形。
      if validator = options[:host_validator]
        return request_validating_hops(method, uri, hop_options, validator)
      end
      start = Time.now
      response = HTTParty.public_send(method, uri.normalize, hop_options)
      log(method:, multipart: true, url: uri, status: response.code, start:)
      bad_response!(response) unless response.code < 400
      return response
    end

    private

    # `upload` が HTTParty へ渡す options。⚠ **呼び出し側の hash を壊さない
    # (#537)。** `||=` と `[]=` は渡された hash そのものへ書き込むので、
    # 使い回されると次の要求へ持ち越される。
    def upload_options(file, options)
      headers = (options[:headers] || {}).dup
      headers['User-Agent'] ||= user_agent
      body = (options[:payload] || options[:body] || {}).dup
      body[:file] = file if file
      return {headers:, body:, multipart: true, timeout: options[:timeout] || timeout}
    end

    # body を伴うメソッド（POST / DELETE / PUT）の共通経路。
    #
    # 括り出す前は delete が `method: :post` でログし、put が `repeat(:delete, ...)`
    # を呼んでいた（いずれもコピペ由来）。ここに寄せて解消している。
    def request_with_body(method, uri, options)
      # ⚠ 呼び出し側の hash を壊さない (#537)。GET / HEAD の経路は #528 で直したが、
      # こちらは同じ型のまま残っていた。⚠⚠ `create_headers` は**渡された hash
      # そのもの**へ Content-Type を書き込むので、headers を使い回す呼び出しでは、
      # JSON でない次の要求へ持ち越される。
      options = options.dup
      options[:headers] = create_headers((options[:headers] || {}).dup)
      options[:body] = create_body(options[:body], options[:headers])
      options[:timeout] ||= timeout
      # ⚠ **GET と同じく max_bytes を効かせる (#538)。** 取り出さないまま
      # HTTParty へ渡すと**黙って捨てられる**ので、呼び出し側は「上限を付けた」と
      # 思い込んだまま上限なしで受け取っていた。
      max_bytes = options.delete(:max_bytes)
      # ⚠⚠ **GET / HEAD と同じく validator を通す (#569)。** ここに分岐が無かった
      # 間、`options[:host_validator]` は HTTParty へ知らないオプションとして渡り
      # **捨てられていた**。`follow_redirects` は既定の true のままなので、
      # 🔴 **初段すら検証せずリダイレクトを追い、リンクローカルまで到達した**
      # （webmock で実測）。⚠ 黙って無視するのが最悪で、呼び出し側は「渡した
      # つもりで無検証」になる — `#head` のコメントが言っているのと同じ形。
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
      options[:timeout] ||= timeout
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

    def user_agent
      return package_class.user_agent
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
