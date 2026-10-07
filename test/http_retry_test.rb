# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  class HTTPRetryTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      return if disable?
      WebMock.disable_net_connect!
      Config.instance['/http/retry/seconds'] = 0
      @http = HTTP.new
      @http.base_uri = 'https://example.com'
      @url = 'https://example.com/api'
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
      Config.instance.reload
    end

    # 一時的な失敗は再送する。
    def test_retry_server_error
      stub_request(:get, @url).to_return(status: 503)

      assert_raise(GatewayError) {@http.get('/api')}
      assert_requested(:get, @url, times: @http.retry_limit)
    end

    def test_retry_too_many_requests
      stub_request(:get, @url).to_return(status: 429)

      assert_raise(GatewayError) {@http.get('/api')}
      assert_requested(:get, @url, times: @http.retry_limit)
    end

    # ⚠ 恒久的な失敗は再送しない。投げ直しても結果は変わらず、待ちと負荷と
    # ログだけが retry_limit 倍になる。
    def test_no_retry_unauthorized
      stub_request(:get, @url).to_return(status: 401)

      assert_raise(GatewayError) {@http.get('/api')}
      assert_requested(:get, @url, times: 1)
    end

    def test_no_retry_unprocessable_entity
      stub_request(:post, @url).to_return(status: 422)

      assert_raise(GatewayError) {@http.post('/api', {body: {}})}
      assert_requested(:post, @url, times: 1)
    end

    def test_no_retry_not_found
      stub_request(:get, @url).to_return(status: 404)

      assert_raise(GatewayError) {@http.get('/api')}
      assert_requested(:get, @url, times: 1)
    end

    # ステータスを取り出せない失敗（接続断など）は再送する。
    def test_retry_connection_error
      stub_request(:get, @url).to_raise(SocketError.new('getaddrinfo'))

      assert_raise(GatewayError) {@http.get('/api')}
      assert_requested(:get, @url, times: @http.retry_limit)
    end

    # 🔴 **`host_validator` を渡した経路でも同じ規則で再送すること (#656)。**
    # ⚠⚠ この経路は `request_hop` が自前で `repeat` を呼ぶ**別の実装**で、上のテストは
    # 1 件も通らない — 「再送しないラッパ」に差し替えても全部緑だった（実測）。
    def test_retry_server_error_with_host_validator
      stub_request(:get, @url).to_return(status: 503)

      assert_raise(GatewayError) {@http.get('/api', {host_validator: ->(_host) {true}})}
      assert_requested(:get, @url, times: @http.retry_limit)
    end

    # ⚠ 恒久的な失敗を再送しないのも同じ。
    def test_no_retry_not_found_with_host_validator
      stub_request(:get, @url).to_return(status: 404)

      assert_raise(GatewayError) {@http.get('/api', {host_validator: ->(_host) {true}})}
      assert_requested(:get, @url, times: 1)
    end

    # 🔴 **`host_validator` を渡した経路でも、400 以上は例外になること (#656)。**
    # ⚠⚠ `bad_response!` の行を消しても全部緑だった（実測）— 上の 2 件は
    # `assert_raise` を持つが、**ここでは「応答を添えること」まで見る**。
    # ⚠ HEAD も同じ経路を通る（サイズのプリフライト）。
    def test_error_status_is_an_error_with_host_validator
      [:get, :head].each do |method|
        stub_request(method, @url).to_return(status: 403)

        error = assert_raise(GatewayError, method.to_s) do
          @http.public_send(method, '/api', {host_validator: ->(_host) {true}})
        end

        assert_equal(403, error.response.code, method.to_s)
      end
    end

    # ⚠⚠ **429 は「いつ再開してよいか」を相手が明示している唯一のステータス**
    # (#525、pooza/makoto2#100)。固定値で叩き直すと、規制されている最中に
    # retry_limit 回連打して規制を長引かせる。
    def test_retry_after_seconds_is_honored
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => '3'})

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_equal([3] * (@http.retry_limit - 1), @slept)
      assert_requested(:get, @url, times: @http.retry_limit)
    end

    # ⚠ **HTTP-date の形もある** (RFC 9110)。
    def test_retry_after_http_date_is_honored
      at = (Time.now + 4).httpdate
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => at})

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_operator(@slept.first, :<=, 5)
      assert_operator(@slept.first, :>=, 3)
    end

    # ⚠ 過去の日付を返されても負数を sleep しない（ArgumentError になる）。
    def test_retry_after_past_date_waits_zero
      at = (Time.now - 60).httpdate
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => at})

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_equal([0] * (@http.retry_limit - 1), @slept)
    end

    # ⚠⚠ **長すぎる待ちを指定されたら、待たずに諦める。** プロセスを何分も
    # 止めるのは呼び出し側の期待を超える。「次の機会に回す」判断は呼ぶ側のもの。
    def test_gives_up_when_retry_after_exceeds_limit
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => '3600'})

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_empty(@slept, '待たないこと')
      assert_requested(:get, @url, times: 1)
    end

    def test_retry_after_limit_is_configurable
      Config.instance['/http/retry/max_seconds'] = 7200
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => '3600'})

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}
      assert_equal([3600] * (@http.retry_limit - 1), @slept)
    end

    # ヘッダが無ければ従来どおり固定値（挙動を変えない）。
    def test_retry_after_absent_falls_back_to_configured_seconds
      Config.instance['/http/retry/seconds'] = 2
      stub_request(:get, @url).to_return(status: 429)

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}
      assert_equal([2] * (@http.retry_limit - 1), @slept)
    end

    # ⚠ 読めない値は固定値へ倒す（ここで諦めると再送そのものが消える）。
    def test_unparsable_retry_after_falls_back_to_configured_seconds
      Config.instance['/http/retry/seconds'] = 2
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => 'soon'})

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}
      assert_equal([2] * (@http.retry_limit - 1), @slept)
    end

    # ⚠⚠ **Mastodon は 429 に `Retry-After` を付けず、`X-RateLimit-Reset`（ISO 8601）だけを
    # 返す**（`config/initializers/rack_attack.rb` の `throttled_responder` と
    # `Api::RateLimitHeaders`）。`Retry-After` が無いときはこちらを読む
    # (pooza/makoto2#425)。
    def test_ratelimit_reset_is_honored_without_retry_after
      at = (Time.now + 4).utc.iso8601(6)
      stub_request(:get, @url).to_return(status: 429, headers: {'X-RateLimit-Reset' => at})

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_operator(@slept.first, :<=, 5)
      assert_operator(@slept.first, :>=, 3)
    end

    # ⚠ **`Retry-After` があればそちらが勝つ**（RFC 9110 のヘッダが正本）。
    def test_retry_after_wins_over_ratelimit_reset
      at = (Time.now + 30).utc.iso8601(6)
      stub_request(:get, @url).to_return(
        status: 429, headers: {'Retry-After' => '3', 'X-RateLimit-Reset' => at},
      )

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_equal([3] * (@http.retry_limit - 1), @slept)
    end

    # 🔴 **投稿の制限（300 本 / 3 時間）の窓は上限を超えるので、待たずに諦める。**
    # ⚠⚠ **いままでは 1 秒間隔で `retry_limit` 回叩き直し、窓が明ける前に使い切っていた**
    # （規制の最中に連打する形そのもの）。
    def test_gives_up_when_ratelimit_reset_exceeds_limit
      at = (Time.now + 3600).utc.iso8601(6)
      stub_request(:get, @url).to_return(status: 429, headers: {'X-RateLimit-Reset' => at})

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_empty(@slept, '待たないこと')
      assert_requested(:get, @url, times: 1)
    end

    # ⚠ 過去の時刻は 0、読めない値は固定値へ倒す（`Retry-After` と同じ扱い）。
    def test_ratelimit_reset_past_or_unparsable
      at = (Time.now - 60).utc.iso8601(6)
      stub_request(:get, @url).to_return(status: 429, headers: {'X-RateLimit-Reset' => at})

      assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}
      assert_equal([0] * (@http.retry_limit - 1), @slept)

      Config.instance['/http/retry/seconds'] = 2
      stub_request(:get, @url).to_return(status: 429, headers: {'X-RateLimit-Reset' => 'soon'})

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}
      assert_equal([2] * (@http.retry_limit - 1), @slept)
    end

    # ⚠ **429 以外では見ない。** 408 / 425 は「相手が意図的に断っている」
    # わけではないので、従来どおり固定値のまま。
    def test_retry_after_is_ignored_for_other_statuses
      Config.instance['/http/retry/seconds'] = 2
      stub_request(:get, @url).to_return(status: 503, headers: {'Retry-After' => '3600'})

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}
      assert_equal([2] * (@http.retry_limit - 1), @slept)
      assert_requested(:get, @url, times: @http.retry_limit)
    end

    # ⚠⚠ **上限は Retry-After 由来の値にだけ掛ける (#549)。** 固定値にも掛けると、
    # `/http/retry/seconds` を上限より大きくしているアプリで、**ヘッダの無い 503 や
    # 接続断まで 1 回で諦める**ようになる（#525 が「ヘッダが無ければ従来どおり」と
    # 約束した挙動に反する）。
    def test_ceiling_does_not_apply_to_fixed_interval
      Config.instance['/http/retry/seconds'] = 120
      stub_request(:get, @url).to_return(status: 503)

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}

      assert_equal([120] * (@http.retry_limit - 1), @slept)
      assert_requested(:get, @url, times: @http.retry_limit)
    end

    def test_ceiling_does_not_apply_to_connection_error
      Config.instance['/http/retry/seconds'] = 120
      stub_request(:get, @url).to_raise(SocketError.new('getaddrinfo'))

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}

      assert_equal([120] * (@http.retry_limit - 1), @slept)
    end

    # ⚠ mkcol は Net::HTTPResponse を添える。**headers を持たない**ので、
    # `response[name]` でも読めること (#549)。
    def test_retry_after_is_read_from_net_http_response
      stub_request(:mkcol, @url).to_return(status: 429, headers: {'Retry-After' => '3'})

      assert_raise(GatewayError) {capture_sleep {@http.mkcol('/api')}}

      assert_equal([3] * (@http.retry_limit - 1), @slept)
    end

    # ⚠⚠ **待ちが長すぎて諦めた回は、それと分かる行を残す (#662)。** `count: 1` の
    # 1 本だけでは `retry_limit` を使い切った回と区別できない。
    def test_log_tells_retry_after_too_long
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => '3600'})

      logged = capture_log {assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}}

      assert_equal(1, logged.size)
      assert_equal(1, logged.first[:count])
      assert_equal(3600, logged.first[:retry_after])
      assert_equal(:retry_after_too_long, logged.first[:gave_up])
      assert_equal(@http.send(:max_retry_seconds), logged.first[:max_seconds])
    end

    # ⚠ `X-RateLimit-Reset` は生の値を残す（規制がいつ解けたはずかを後から追う）。
    def test_log_keeps_ratelimit_reset
      at = (Time.now + 3600).utc.iso8601(6)
      stub_request(:get, @url).to_return(status: 429, headers: {'X-RateLimit-Reset' => at})

      logged = capture_log {assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}}

      assert_equal(1, logged.size)
      assert_equal(at, logged.first[:ratelimit_reset])
      assert_equal(:retry_after_too_long, logged.first[:gave_up])
      assert_operator(logged.first[:retry_after], :>, 3500)
    end

    # 待って再送した回は `gave_up` を持たず、使い切った最後の 1 回だけが持つ。
    # ⚠ 行は従来どおり落ちた試行 1 回につき 1 本（利用側が `count` の行を数えている）。
    def test_log_tells_retry_limit
      stub_request(:get, @url).to_return(status: 429, headers: {'Retry-After' => '3'})

      logged = capture_log {assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}}

      assert_equal((1..@http.retry_limit).to_a, logged.map {|v| v[:count]})
      assert_equal([3] * @http.retry_limit, logged.map {|v| v[:retry_after]})
      assert_equal(([nil] * (@http.retry_limit - 1)) + [:retry_limit], logged.map {|v| v[:gave_up]})
      assert_not_include(logged.last.keys, :max_seconds)
    end

    def test_log_tells_not_retryable
      stub_request(:get, @url).to_return(status: 401)

      logged = capture_log {assert_raise(GatewayError) {@http.get('/api')}}

      assert_equal(1, logged.size)
      assert_equal(:not_retryable, logged.first[:gave_up])
    end

    # ⚠ 429 以外は待ちのキーを足さない（固定値で待つので、読んだ値が無い）。
    def test_log_has_no_wait_keys_for_other_statuses
      stub_request(:get, @url).to_return(
        status: 503, headers: {'Retry-After' => '3', 'X-RateLimit-Reset' => Time.now.utc.iso8601},
      )

      logged = capture_log {assert_raise(GatewayError) {capture_sleep {@http.get('/api')}}}

      assert_equal(@http.retry_limit, logged.size)
      logged.each do |entry|
        assert_not_include(entry.keys, :retry_after)
        assert_not_include(entry.keys, :ratelimit_reset)
      end
    end

    # ⚠ **想定内の状態コードで落ちた試行は、行を出さない (#672)。** 例外は投げる。
    def test_quiet_statuses_silences_the_line_but_still_raises
      stub_request(:head, @url).to_return(status: 403)

      error = nil
      logged = capture_log do
        error = assert_raise(GatewayError) {@http.head('/api', quiet_statuses: [403, 405])}
      end

      assert_equal(403, error.source_status)
      assert_empty(logged)
      assert_requested(:head, @url, times: 1)
    end

    # ⚠⚠ **指定が無ければ、行の形は従来どおり**（1 試行 1 行・`count` を持つ）。
    def test_quiet_statuses_is_optional
      stub_request(:head, @url).to_return(status: 403)

      logged = capture_log {assert_raise(GatewayError) {@http.head('/api')}}

      assert_equal([1], logged.map {|entry| entry[:count]})
      assert_equal([:not_retryable], logged.map {|entry| entry[:gave_up]})
    end

    # ⚠ 挙げていない状態は出す。
    def test_quiet_statuses_keeps_other_statuses
      stub_request(:get, @url).to_return(status: 404)

      logged = capture_log {assert_raise(GatewayError) {@http.get('/api', quiet_statuses: [403])}}

      assert_equal(1, logged.size)
    end

    # 🔴 **再送する状態は、指定されても黙らせない (#672)。** あの行は「なぜ待った・
    # 諦めたか」を運び、利用側が落ちた試行として数えている（#662）。
    def test_quiet_statuses_does_not_silence_retried_statuses
      stub_request(:get, @url).to_return(status: 503)

      logged = capture_log {assert_raise(GatewayError) {@http.get('/api', quiet_statuses: [503])}}

      assert_equal(@http.retry_limit, logged.size)
      assert_equal(:retry_limit, logged.last[:gave_up])
    end

    # ⚠ body を伴うメソッドにも効く。⚠⚠ **呼び出し側の hash は壊さない**（#528 / #537）。
    def test_quiet_statuses_on_request_with_body
      stub_request(:post, @url).to_return(status: 403)
      options = {body: {}, quiet_statuses: [403]}

      logged = capture_log {assert_raise(GatewayError) {@http.post('/api', options)}}

      assert_empty(logged)
      assert_equal({body: {}, quiet_statuses: [403]}, options)
    end

    # 🔴 **`host_validator` の経路にも効く (#672)。** ⚠⚠ プリフライトの HEAD は validator と
    # 一緒に使われる（mulukhiya-toot-proxy#4523）ので、**こちらに届かないと依頼の形で効かない**。
    # ⚠ リダイレクトの先の答えにも効く。
    def test_quiet_statuses_on_validating_hops
      stub_request(:head, @url).to_return(status: 302, headers: {'Location' => 'https://example.org/x'})
      stub_request(:head, 'https://example.org/x').to_return(status: 405)

      logged = capture_log do
        assert_raise(GatewayError) do
          @http.head('/api', quiet_statuses: [403, 405], host_validator: ->(_host) {true})
        end
      end

      assert_empty(logged)
      assert_requested(:head, 'https://example.org/x', times: 1)
    end

    # ⚠⚠ **HTTParty へは渡さない。** 知らないオプションは黙って捨てられるので、
    # 渡っていないことを直に見る。
    def test_quiet_statuses_is_not_passed_to_httparty
      stub_request(:get, @url).to_return(status: 200)
      seen = []
      @http.define_singleton_method(:execute) do |method, uri, options, max_bytes = nil|
        seen.push(options.keys)
        super(method, uri, options, max_bytes)
      end

      @http.get('/api', quiet_statuses: [403])
      @http.get('/api', quiet_statuses: [403], host_validator: ->(_host) {true})

      assert_equal(2, seen.size)
      assert_false(seen.flatten.include?(:quiet_statuses))
    end

    # 🔴 **応答を持たない失敗は黙らせない (#672)。** ⚠⚠ `TooLargeError` も
    # `:not_retryable` で、応答を持たない例外の `source_status` は 502 へ倒れる —
    # `response` を見ないと「502 は想定内」の指定でこの行まで消える。
    def test_quiet_statuses_does_not_silence_errors_without_a_response
      stub_request(:get, @url).to_return(status: 200, body: 'x' * 64)

      error = nil
      logged = capture_log do
        error = assert_raise(TooLargeError) {@http.get('/api', max_bytes: 8, quiet_statuses: [502])}
      end

      assert_equal(502, error.source_status)
      assert_equal(1, logged.size)
    end

    private

    # sleep を捕まえる。⚠ 実際に待つとテストが retry_limit 倍の時間を食う。
    def capture_sleep
      @slept = []
      slept = @slept
      HTTP.define_method(:sleep) do |seconds|
        slept.push(seconds)
        return 0
      end
      yield
    ensure
      HTTP.remove_method(:sleep)
    end

    # ログの行を捕まえる。
    def capture_log
      logged = []
      @http.instance_variable_get(:@logger).define_singleton_method(:error) {|entry| logged.push(entry)}
      yield
      return logged
    end
  end
end
