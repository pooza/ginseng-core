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

    # ⚠ **上限を超えたら error 行を 1 本残す（6.0.0 のリリース前レビュー）。** `repeat` の外なので、
    # 残さないと info 行が並ぶだけになる。
    def test_too_many_redirects_is_logged
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => @url})
      logged = capture_error_log {assert_raise(GatewayError) {@http.get('/api', {max_redirects: 2})}}

      assert_equal([:too_many_redirects], logged.map {|v| v[:gave_up]})
    end

    # 🔴🔴 **http / https 以外の行き先は追わず、行にも例外にも平文で出さない（6.0.0 のリリース前レビュー）。**
    # ⚠⚠ ログのマスクは `scheme://` の形しか伏せないので、行き先を `url:` 欄へ渡すと平文で出た。
    # ⚠ 送れない行き先なので撃ち直さない（以前は `retry_limit` 回撃っていた）。
    def test_unsupported_redirect_scheme_is_refused
      ['myapp:/callback?code=SECRET', 'mailto:me@example.com?body=SECRET', 'javascript:alert(SECRET)'].each do |location|
        WebMock.reset!
        stub_request(:get, @url).to_return(status: 302, headers: {'Location' => location})
        logger = @http.instance_variable_get(:@logger)
        error = nil
        logged = capture_error_log {error = assert_raise(GatewayError, location) {@http.get('/api')}}

        assert_not_include(error.message, 'SECRET', location)
        assert_equal(1, logged.size, location)
        assert_not_include(logger.create_message(logged.first).to_json, 'SECRET', location)
        assert_equal(@url, logged.first[:url], '行には直前のホップの URL を残す')
        assert_requested(:get, @url, times: 1)
      end
    end

    # 🔴 **`default_params` はリダイレクト先へ持ち越さない（6.0.0 のリリース前レビュー）。** HTTParty は
    # ホップごとにクエリへ足すので、残すと別ホストの 2 段目に `?api_key=…` が付く。
    def test_default_params_are_not_carried
      stub_request(:get, "#{@url}?api_key=SECRET").to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      @http.get('/api', {default_params: {api_key: 'SECRET'}})

      assert_requested(:get, ELSEWHERE)
      assert_not_requested(:get, "#{ELSEWHERE}?api_key=SECRET")
    end

    # 🔴 **対照: HTTParty に追わせると付かない。** ⚠ 5.x の既定の経路と同じ結果であることの固定。
    def test_httparty_alone_drops_default_params
      stub_request(:get, "#{@url}?api_key=SECRET").to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      HTTParty.get(@url, default_params: {api_key: 'SECRET'})

      assert_requested(:get, ELSEWHERE)
    end

    # 🔴 **GET の本文は 307 でも撃ち直さない（6.0.0 のリリース前レビュー）。** 5.x の HTTParty と同じ。
    def test_get_body_is_dropped_on_temporary_redirect
      stub_request(:get, @url).to_return(status: 307, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      @http.get('/api', {body: {'client_secret' => 'SECRET'}})

      assert_requested(:get, ELSEWHERE) {|req| req.body.blank?}
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
    # 🔴🔴 **2 段目以降のホップの URL は、クエリとフラグメントを落として行に出す (#717)。**
    # ⚠⚠ 相手が選んだ URL は、伏せる一覧に無い名前の資格情報を運ぶ（OAuth 1.0a・CAS・
    # Google Apps Script の 302 先）。6.0.0 からホップごとの行に平文で出ていた。
    # ⚠ 初段は呼び出し側が組んだ URL なので落とさない。要求そのものはクエリ付きで送る。
    def test_later_hops_are_logged_without_query
      moved = "#{ELSEWHERE}?oauth_token=SECRET&user_content_key=SECRET#ticket=SECRET"
      stub_request(:get, "#{@url}?page=2").to_return(status: 302, headers: {'Location' => moved})
      stub_request(:get, "#{ELSEWHERE}?oauth_token=SECRET&user_content_key=SECRET").to_return(status: 200)
      logged = []
      @http.instance_variable_get(:@logger).define_singleton_method(:info) {|entry| logged.push(entry)}

      @http.get('/api?page=2')

      assert_equal([["#{@url}?page=2", 302], [ELSEWHERE, 200]], logged.map {|v| [v[:url], v[:status]]})
      assert_not_include(logged.map {|v| Logger.new.create_message(v)}.to_s, 'SECRET')
      assert_requested(:get, "#{ELSEWHERE}?oauth_token=SECRET&user_content_key=SECRET")
    end

    # ⚠ 2 段目で落ちた行（`repeat` の error）も同じ。
    def test_failure_of_a_later_hop_is_logged_without_query
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => "#{ELSEWHERE}?ticket=ST-SECRET"})
      stub_request(:get, "#{ELSEWHERE}?ticket=ST-SECRET").to_return(status: 404)

      logged = capture_error_log {assert_raise(GatewayError) {@http.get('/api')}}

      assert_equal([ELSEWHERE], logged.map {|v| v[:url]})
      assert_not_include(logged.map {|v| Logger.new.create_message(v)}.to_s, 'SECRET')
    end

    # ⚠ 2 段目が読めない行き先へ飛ばしたとき、行に残す「直前のホップ」も同じ。
    def test_invalid_location_after_a_later_hop_is_logged_without_query
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => "#{ELSEWHERE}?ticket=ST-SECRET"})
      stub_request(:get, "#{ELSEWHERE}?ticket=ST-SECRET").to_return(
        status: 302, headers: {'Location' => 'myapp:/cb?code=SECRET'},
      )

      logged = capture_error_log {assert_raise(GatewayError) {@http.get('/api')}}

      assert_equal([[:invalid_location, ELSEWHERE]], logged.map {|v| [v[:gave_up], v[:url]]})
      assert_not_include(logged.map {|v| Logger.new.create_message(v)}.to_s, 'SECRET')
    end

    # ⚠ 諦めた行（`too_many_redirects`）の URL も同じ。
    def test_too_many_redirects_is_logged_without_query
      stub_request(:get, @url).to_return(status: 302, headers: {'Location' => "#{ELSEWHERE}?ticket=ST-SECRET"})
      stub_request(:get, "#{ELSEWHERE}?ticket=ST-SECRET").to_return(
        status: 302, headers: {'Location' => "#{ELSEWHERE}?ticket=ST-SECRET"},
      )

      logged = capture_error_log {assert_raise(GatewayError) {@http.get('/api', {max_redirects: 2})}}

      assert_equal([[:too_many_redirects, ELSEWHERE]], logged.map {|v| [v[:gave_up], v[:url]]})
    end

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
      assert_requested(:get, SAME_ORIGIN) {|req| req.body.blank?}
    end

    # ⚠ 307 は POST のまま本文ごと撃ち直す（HTTParty と同じ規則）。
    def test_post_is_kept_on_temporary_redirect
      stub_request(:post, @url).to_return(status: 307, headers: {'Location' => SAME_ORIGIN})
      stub_request(:post, SAME_ORIGIN).to_return(status: 200)

      @http.post('/api', {body: {a: 1}})

      assert_requested(:post, SAME_ORIGIN, body: {a: 1}.to_json)
    end

    # 🔴🔴 **読めない `Location` の秘密を、例外にも行にも平文で出さない（#743 Codex P2 / #695）。**
    # ⚠ 5.x の既定の経路は HTTParty が追っていて伏せてあった。validator の経路も同じ扱いにする。
    def test_unreadable_location_is_redacted
      ['https://[::1/callback?code=SECRET', 'http://h.example/a b?code=SECRET'].each do |location|
        [{}, {host_validator: ->(_host) {true}}].each do |options|
          WebMock.reset!
          stub_request(:get, @url).to_return(status: 302, headers: {'Location' => location})
          logged = []
          @http.instance_variable_get(:@logger).define_singleton_method(:error) {|entry| logged.push(entry)}

          error = assert_raise(GatewayError, location) {@http.get('/api', options)}
          chain = []
          cause = error
          while cause
            chain.push("#{cause.class}: #{cause.message}")
            cause = cause.cause
          end

          assert_not_include(chain.join("\n"), 'SECRET', "#{location} #{options.keys}")
          assert_equal(1, logged.size, location)
          assert_equal(:invalid_location, logged.first[:gave_up])
          assert_not_include(logged.first[:error].message, 'SECRET')
        end
      end
    end

    # ⚠ **`upload` も既定で自前で追う。** 5.x では HTTParty に直に渡していた。
    def test_upload_drops_credentials_across_origins
      stub_request(:post, @url).to_return(status: 307, headers: {'Location' => ELSEWHERE})
      stub_request(:post, ELSEWHERE).to_return(status: 200)

      @http.upload('/api', File.join(Environment.dir, 'images/pooza.png'), {headers: {'X-Api-Key' => 'SECRET'}})

      assert_requested(:post, ELSEWHERE)
      assert_not_requested(:post, ELSEWHERE, headers: {'X-Api-Key' => 'SECRET'})
    end

    private

    def capture_error_log
      logged = []
      @http.instance_variable_get(:@logger).define_singleton_method(:error) {|entry| logged.push(entry)}
      yield
      return logged
    end
  end
end
