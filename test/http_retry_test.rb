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
  end
end
