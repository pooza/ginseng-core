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

    # ⚠ **429 以外では見ない。** 408 / 425 は「相手が意図的に断っている」
    # わけではないので、従来どおり固定値のまま。
    def test_retry_after_is_ignored_for_other_statuses
      Config.instance['/http/retry/seconds'] = 2
      stub_request(:get, @url).to_return(status: 503, headers: {'Retry-After' => '3600'})

      assert_raise(GatewayError) {capture_sleep {HTTP.new.get(@url)}}
      assert_equal([2] * (@http.retry_limit - 1), @slept)
      assert_requested(:get, @url, times: @http.retry_limit)
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
  end
end
