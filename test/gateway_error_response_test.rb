# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # GatewayError が上流のレスポンスを持ち帰ること (mulukhiya-toot-proxy#4480)。
  #
  # 従来は "Bad response NNN" という文字列だけが残り、上流が返した理由
  # （Misskey の TOO_MANY_DRAFTS、Mastodon の Validation failed 等）が
  # プロキシの中で失われていた。
  class GatewayErrorResponseTest < TestCase
    UPSTREAM = 'https://example.com/api/notes/create'

    # 上流のレスポンスの代役。source_body / source_status が見るのは code と body だけ。
    FakeResponse = Struct.new(:code, :body)

    def setup
      @http = HTTP.new
      @http.retry_limit = 1
      WebMock.disable_net_connect!
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def test_post_attaches_upstream_response
      body = {error: {code: 'TOO_MANY_DRAFTS', id: 'deadbeef'}}.to_json
      WebMock.stub_request(:post, UPSTREAM).to_return(status: 400, body:, headers: {'Content-Type' => 'application/json'})

      error = assert_raise(GatewayError) {@http.post(UPSTREAM, body: {})}

      assert_equal('Bad response 400', error.message)
      assert_equal(400, error.source_status)
      assert_equal('TOO_MANY_DRAFTS', error.source_body.dig('error', 'code'))
    end

    def test_get_attaches_upstream_response
      WebMock.stub_request(:get, UPSTREAM).to_return(status: 422, body: {error: 'Validation failed'}.to_json)

      error = assert_raise(GatewayError) {@http.get(UPSTREAM)}

      assert_equal(422, error.source_status)
      assert_equal('Validation failed', error.source_body['error'])
    end

    # ⚠ 上流が HTML を返すことがある（nginx の 502 等）。素通しすると
    # プロキシが他人の HTML を吐くので、JSON として読めた場合のみ返す。
    def test_source_body_is_nil_for_html
      WebMock.stub_request(:get, UPSTREAM).to_return(status: 502, body: '<html><body>Bad Gateway</body></html>')

      error = assert_raise(GatewayError) {@http.get(UPSTREAM)}

      assert_nil(error.source_body)
      assert_equal(502, error.source_status)
    end

    def test_source_body_is_nil_for_oversize_body
      WebMock.stub_request(:get, UPSTREAM).to_return(status: 400, body: {error: 'x' * 70_000}.to_json)

      error = assert_raise(GatewayError) {@http.get(UPSTREAM)}

      assert_nil(error.source_body)
    end

    def test_source_body_is_nil_for_json_scalar
      WebMock.stub_request(:get, UPSTREAM).to_return(status: 400, body: '"just a string"')

      error = assert_raise(GatewayError) {@http.get(UPSTREAM)}

      assert_nil(error.source_body)
    end

    # response を持たない GatewayError（接続失敗を包み直したもの等）は従来どおり。
    def test_falls_back_to_message_parsing_without_response
      error = GatewayError.new('Bad response 404')

      assert_nil(error.response)
      assert_equal(404, error.source_status)
      assert_nil(error.source_body)
    end

    def test_status_is_502_when_message_has_no_code
      error = GatewayError.new('Failed to open TCP connection')

      assert_equal(502, error.source_status)
    end

    # メモ化しても結果が変わらないこと。エラー経路は source_body を複数回
    # 呼ぶ（silent 判定 → レンダリング）ので、毎回 JSON.parse していた
    # (pooza/mulukhiya-toot-proxy#4537)。
    def test_source_body_is_memoized
      WebMock.stub_request(:get, UPSTREAM).to_return(status: 400, body: {error: 'x'}.to_json)

      error = assert_raise(GatewayError) {@http.get(UPSTREAM)}

      assert_same(error.source_body, error.source_body)
    end

    # ⚠ メモ化は max_bytes ごと。上限を変えて呼び直したときに前の結果を
    # 返すと、上限の意味が消える。
    def test_source_body_memoization_respects_max_bytes
      WebMock.stub_request(:get, UPSTREAM).to_return(status: 400, body: {error: 'x'}.to_json)

      error = assert_raise(GatewayError) {@http.get(UPSTREAM)}

      assert_equal('x', error.source_body['error'])
      assert_nil(error.source_body(max_bytes: 4))
      assert_equal('x', error.source_body['error'])
    end

    # ⚠⚠ **response を後から差し替えたら source_body も付いてくること (#531)。**
    # メモ化は max_bytes ごとで、**nil も結果として持つ**（key? で判定する）ので、
    # 評価したあとに response を添えると「添えたのに読めない」になっていた。
    def test_source_body_follows_replaced_response
      error = GatewayError.new('Bad response 500')

      assert_nil(error.source_body, 'response が無いうちは nil（ここでメモ化される）')

      error.response = FakeResponse.new(500, {error: 'later'}.to_json)

      assert_equal('later', error.source_body['error'])
    end

    # 差し替え前の値を返し続けないこと。
    def test_source_body_is_dropped_on_replacement
      error = GatewayError.new('Bad response 500')
      error.response = FakeResponse.new(500, {error: 'first'}.to_json)

      assert_equal('first', error.source_body['error'])

      error.response = FakeResponse.new(500, {error: 'second'}.to_json)

      assert_equal('second', error.source_body['error'])
    end

    # ⚠ repeat が包み直すと response が落ちる。再送対象（5xx）でも、
    # 打ち切り時に上流のボディが残っていること。
    def test_response_survives_retry_exhaustion
      body = {error: {code: 'INTERNAL_ERROR'}}.to_json
      WebMock.stub_request(:get, UPSTREAM).to_return(status: 503, body:)

      error = assert_raise(GatewayError) {@http.get(UPSTREAM)}

      assert_equal(503, error.source_status)
      assert_equal('INTERNAL_ERROR', error.source_body.dig('error', 'code'))
    end
  end
end
