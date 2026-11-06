# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # validator を渡さない既定の経路のリダイレクト (#655)。
  #
  # 🔴🔴 **5.x までは HTTParty に追わせていて、1 段目の `Set-Cookie` が別ホストの 2 段目へ
  # 送られた**（`capture_cookies`）。⚠⚠ 上流が別ホストで落とすのは `Authorization` と
  # `basic_auth` だけで、`X-Api-Key` のような名前のヘッダや `cookies:` は素通りしていた。
  # 6.0.0 から、既定の経路も `host_validator` を渡した経路と同じ追い方をする。
  #
  # ⚠ validator を渡した経路の細部（body の持ち越し・304・pinning など）は
  # `HTTPHostValidatorTest` が押さえる。ここは「validator が無くても同じ扱いになること」を見る。
  class HTTPRedirectTest < TestCase
    ORIGIN = 'https://example.com'
    ELSEWHERE = 'https://elsewhere.example.com/moved'
    SAME_ORIGIN = 'https://example.com/moved'

    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      return if disable?
      WebMock.disable_net_connect!
      @http = HTTP.new
      @http.base_uri = ORIGIN
      @url = "#{ORIGIN}/api"
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    # 🔴🔴 **#655 の本体。** 1 段目の `Set-Cookie` は、別ホストの 2 段目へ送らない。
    def test_set_cookie_of_first_hop_does_not_reach_another_host
      stub_request(:get, @url).to_return(
        status: 302, headers: {'Location' => ELSEWHERE, 'Set-Cookie' => 'sid=SECRET; Path=/'},
      )
      stub_request(:get, ELSEWHERE).to_return(status: 200, body: '2 段目')

      assert_equal('2 段目', @http.get('/api').body)
      assert_requested(:get, ELSEWHERE)
      assert_not_requested(:get, ELSEWHERE, headers: {'Cookie' => 'sid=SECRET'})
    end

    # 🔴 **対照: HTTParty に追わせると届く。** ⚠⚠ これが落ちたら、上のテストは「直したから」ではなく
    # 「上流がもともと送らないから」緑になっている（「緑は守っている証拠にならない」）。
    def test_httparty_alone_forwards_the_cookie
      stub_request(:get, @url).to_return(
        status: 302, headers: {'Location' => ELSEWHERE, 'Set-Cookie' => 'sid=SECRET; Path=/'},
      )
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      HTTParty.get(@url)

      assert_requested(:get, ELSEWHERE, headers: {'Cookie' => 'sid=SECRET'})
    end

    # ⚠ **同じオリジンでも、途中の `Set-Cookie` は持ち越さない。** validator を渡した経路と同じ
    # 扱い（あちらも持ち越していなかった）。⚠⚠ HTTParty は持ち越していたので、ここは 6.0.0 で
    # 変わった挙動として固定する。
    def test_set_cookie_is_not_carried_even_within_the_origin
      stub_request(:get, @url).to_return(
        status: 302, headers: {'Location' => SAME_ORIGIN, 'Set-Cookie' => 'sid=SECRET; Path=/'},
      )
      stub_request(:get, SAME_ORIGIN).to_return(status: 200)

      @http.get('/api')

      assert_requested(:get, SAME_ORIGIN)
      assert_not_requested(:get, SAME_ORIGIN, headers: {'Cookie' => 'sid=SECRET'})
    end

    # 🔴 **オリジンをまたいだら、資格情報のヘッダとオプションを落とす。** ⚠⚠ `X-Api-Key` と
    # `cookies:` は、HTTParty に任せていた間は別ホストへ届いていた。
    def test_credentials_are_dropped_across_origins
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      @http.get('/api', {
        headers: {'X-Api-Key' => 'SECRET', 'Authorization' => 'Bearer SECRET', 'X-Trace' => 'keep'},
        cookies: {sid: 'SECRET'},
      })

      assert_requested(:get, ELSEWHERE, headers: {'X-Trace' => 'keep'})
      ['X-Api-Key', 'Cookie'].each do |name|
        assert_not_requested(:get, ELSEWHERE, headers: {name => /SECRET/})
      end
      assert_not_requested(:get, ELSEWHERE, headers: {'Authorization' => 'Bearer SECRET'})
    end

    # 🔴 **対照: HTTParty に追わせると `X-Api-Key` は届く。**
    def test_httparty_alone_forwards_custom_credential_headers
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      HTTParty.get(@url, headers: {'X-Api-Key' => 'SECRET'})

      assert_requested(:get, ELSEWHERE, headers: {'X-Api-Key' => 'SECRET'})
    end

    # ⚠ **同じオリジンなら資格情報は落とさない。** 落とすと、正規に 301 を返す相手（末尾の
    # スラッシュの補完など）で認証が外れる。
    def test_credentials_are_kept_within_the_origin
      stub_request(:get, @url).to_return(status: 301, headers: {'Location' => SAME_ORIGIN})
      stub_request(:get, SAME_ORIGIN).to_return(status: 200)

      @http.get('/api', {headers: {'X-Api-Key' => 'SECRET'}})

      assert_requested(:get, SAME_ORIGIN, headers: {'X-Api-Key' => 'SECRET'})
    end

    # ⚠ `follow_redirects: false` なら 3xx をそのまま返す（5.x と同じ）。
    def test_follow_redirects_false_returns_the_redirect
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => ELSEWHERE})

      assert_equal(302, @http.get('/api', {follow_redirects: false}).code)
      assert_not_requested(:get, ELSEWHERE)
    end

    # ⚠ 上限を超えたら `GatewayError`。`max_redirects:` で変えられる。
    def test_too_many_redirects
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => @url})

      error = assert_raise(GatewayError) {@http.get('/api', {max_redirects: 2})}

      assert_include(error.message, 'Too many redirects (2)')
      assert_requested(:get, @url, times: 3)
    end

    # ⚠ **ホップごとにログが 1 行出る。** 5.x までは最後の答えの 1 行だけだった。
    def test_each_hop_is_logged
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)
      logged = []
      @http.instance_variable_get(:@logger).define_singleton_method(:info) {|entry| logged.push(entry)}

      @http.get('/api')

      assert_equal([[@url, 302], [ELSEWHERE, 200]], logged.map {|v| [v[:url], v[:status]]})
    end

    # ⚠ **HEAD は HEAD のまま追う**（`SAFE_METHODS`）。⚠ HTTParty も HEAD のまま追う（実測）ので、
    # 5.x から変わっていないことの固定。🔴 GET に化けると、サイズのプリフライトが本文を丸ごと取る。
    def test_head_stays_head
      stub_request(:head, @url).to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:head, ELSEWHERE).to_return(status: 200)

      assert_equal(200, @http.head('/api').code)
      assert_requested(:head, ELSEWHERE)
    end

    # ⚠ 301 / 302 の POST は GET に化け、本文を捨てる（HTTParty と同じ規則）。
    def test_post_becomes_get_on_found
      stub_request(:post, @url).to_return(status: 302, headers: {'Location' => SAME_ORIGIN})
      stub_request(:get, SAME_ORIGIN).to_return(status: 200)

      assert_equal(200, @http.post('/api', {body: {a: 1}}).code)
      assert_requested(:get, SAME_ORIGIN)
    end

    # ⚠ 307 は POST のまま本文ごと撃ち直す（HTTParty と同じ規則）。
    def test_post_is_kept_on_temporary_redirect
      stub_request(:post, @url).to_return(status: 307, headers: {'Location' => SAME_ORIGIN})
      stub_request(:post, SAME_ORIGIN).to_return(status: 200)

      @http.post('/api', {body: {a: 1}})

      assert_requested(:post, SAME_ORIGIN, body: {a: 1}.to_json)
    end

    # ⚠ **`upload` も既定で自前で追う。** 5.x では HTTParty に直に渡していた。
    def test_upload_drops_credentials_across_origins
      stub_request(:post, @url).to_return(status: 307, headers: {'Location' => ELSEWHERE})
      stub_request(:post, ELSEWHERE).to_return(status: 200)

      @http.upload('/api', File.join(Environment.dir, 'images/pooza.png'), {headers: {'X-Api-Key' => 'SECRET'}})

      assert_requested(:post, ELSEWHERE)
      assert_not_requested(:post, ELSEWHERE, headers: {'X-Api-Key' => 'SECRET'})
    end
  end
end
