# frozen_string_literal: true

require 'webmock/test_unit'
require 'tempfile'

module Ginseng
  # host_validator によるリダイレクト各ホップの検証 (mulukhiya-toot-proxy#4410)
  class HTTPHostValidatorTest < TestCase
    def setup
      @http = HTTP.new
      WebMock.disable_net_connect!
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def public_hosts(*hosts)
      return ->(host) {hosts.include?(host)}
    end

    def test_follows_redirect_when_every_hop_is_allowed
      WebMock.stub_request(:get, 'https://script.google.com/exec')
        .to_return(status: 302, headers: {'Location' => 'https://script.googleusercontent.com/echo'})
      WebMock.stub_request(:get, 'https://script.googleusercontent.com/echo')
        .to_return(status: 200, body: '{"ok":true}')

      response = @http.get(
        'https://script.google.com/exec',
        host_validator: public_hosts('script.google.com', 'script.googleusercontent.com'),
      )

      assert_equal(200, response.code)
      assert_equal('{"ok":true}', response.body)
    end

    # ⚠⚠ **同じ options を head と get で使い回しても validator が残ること (#528)。**
    # 以前は request が options.delete(:host_validator) で呼び出し側の hash を壊して
    # いたため、**プリフライト (HEAD) を通した時点で validator が消え、本命の GET が
    # 無検証で撃たれていた**。#head のコメントが勧めている使い方そのものが壊れており、
    # 「プリフライトを足したせいで検証が外れる」という裏返しだった。
    def test_keeps_host_validator_for_reused_options
      WebMock.stub_request(:head, 'https://example.com/large.png').to_return(status: 200)
      WebMock.stub_request(:get, 'https://example.com/large.png').to_return(status: 200, body: 'x')
      hosts = []
      options = {host_validator: ->(host) {hosts.push(host) && true}}

      @http.head('https://example.com/large.png', options)
      @http.get('https://example.com/large.png', options)

      assert_equal(['example.com', 'example.com'], hosts)
      assert_equal([:host_validator], options.keys)
    end

    # ⚠ ヘッダも呼び出し側の hash を汚さない。User-Agent が書き戻されると、
    # 同じ hash を使い回す次の要求へ持ち越される。
    def test_does_not_pollute_caller_headers
      WebMock.stub_request(:get, 'https://example.com/').to_return(status: 200, body: 'x')
      headers = {}
      options = {headers:}

      @http.get('https://example.com/', options)

      assert_empty(headers)
      assert_equal([:headers], options.keys)
    end

    def test_rejects_redirect_to_internal_host
      WebMock.stub_request(:get, 'https://example.com/exec')
        .to_return(status: 302, headers: {'Location' => 'http://169.254.169.254/latest/meta-data/'})

      error = assert_raise(GatewayError) do
        @http.get('https://example.com/exec', host_validator: public_hosts('example.com'))
      end

      assert_match(/Rejected host/, error.message)
      assert_not_requested(:get, 'http://169.254.169.254/latest/meta-data/')
    end

    def test_rejects_first_hop
      error = assert_raise(GatewayError) do
        @http.get('http://127.0.0.1/secret', host_validator: public_hosts('example.com'))
      end

      assert_match(/Rejected host/, error.message)
      assert_not_requested(:get, 'http://127.0.0.1/secret')
    end

    def test_resolves_relative_location
      WebMock.stub_request(:get, 'https://example.com/a').to_return(status: 302, headers: {'Location' => '/b'})
      WebMock.stub_request(:get, 'https://example.com/b').to_return(status: 200, body: 'ok')

      response = @http.get('https://example.com/a', host_validator: public_hosts('example.com'))

      assert_equal('ok', response.body)
    end

    def test_raises_on_redirect_loop
      WebMock.stub_request(:get, 'https://example.com/loop')
        .to_return(status: 302, headers: {'Location' => 'https://example.com/loop'})

      error = assert_raise(GatewayError) do
        @http.get('https://example.com/loop', host_validator: public_hosts('example.com'))
      end

      assert_match(/Too many redirects/, error.message)
    end

    # validator を渡さない既定の経路は従来どおり HTTParty に追従させる。
    def test_without_validator_keeps_httparty_behavior
      WebMock.stub_request(:get, 'https://example.com/plain').to_return(status: 200, body: 'plain')

      assert_equal('plain', @http.get('https://example.com/plain').body)
    end

    # HEAD も同じ検証を通す (mulukhiya-toot-proxy#4523)。
    # サイズのプリフライトで GET の前に HEAD を撃つ呼び出し側があり、GET だけ
    # 守っても HEAD が素通りするなら SSRF 対策にならない。
    def test_head_rejects_first_hop
      error = assert_raise(GatewayError) do
        @http.head('http://127.0.0.1/secret', host_validator: public_hosts('example.com'))
      end

      assert_match(/Rejected host/, error.message)
      assert_not_requested(:head, 'http://127.0.0.1/secret')
    end

    def test_head_rejects_redirect_to_internal_host
      WebMock.stub_request(:head, 'https://example.com/exec')
        .to_return(status: 302, headers: {'Location' => 'http://169.254.169.254/latest/meta-data/'})

      error = assert_raise(GatewayError) do
        @http.head('https://example.com/exec', host_validator: public_hosts('example.com'))
      end

      assert_match(/Rejected host/, error.message)
      assert_not_requested(:head, 'http://169.254.169.254/latest/meta-data/')
    end

    def test_head_follows_redirect_when_every_hop_is_allowed
      WebMock.stub_request(:head, 'https://script.google.com/exec')
        .to_return(status: 302, headers: {'Location' => 'https://script.googleusercontent.com/echo'})
      WebMock.stub_request(:head, 'https://script.googleusercontent.com/echo')
        .to_return(status: 200, headers: {'Content-Length' => '12'})

      response = @http.head(
        'https://script.google.com/exec',
        host_validator: public_hosts('script.google.com', 'script.googleusercontent.com'),
      )

      assert_equal(200, response.code)
      assert_equal('12', response.headers['content-length'])
    end

    def test_head_without_validator_keeps_httparty_behavior
      WebMock.stub_request(:head, 'https://example.com/plain').to_return(status: 200, headers: {'Content-Length' => '3'})

      assert_equal('3', @http.head('https://example.com/plain').headers['content-length'])
    end

    # ⚠ **名前で検証して名前で接続すると DNS リバインディングで抜けられる**
    # (mulukhiya-toot-proxy#4524)。validator が IP を返したら、その IP へ
    # 接続するよう HTTParty のアダプタを差し替える。
    def test_validate_host_returns_pinned_address
      uri = URI.parse('https://example.com/exec')

      assert_equal('203.0.113.1', @http.send(:validate_host!, uri, ->(_host) {'203.0.113.1'}))
    end

    # 真偽値を返す従来の validator はそのまま動く（pinning しない）。
    def test_validate_host_keeps_boolean_validator
      uri = URI.parse('https://example.com/exec')

      assert_nil(@http.send(:validate_host!, uri, ->(_host) {true}))
      assert_raise(GatewayError) {@http.send(:validate_host!, uri, ->(_host) {false})}
    end

    def test_pin_address_wires_adapter
      options = PinnedAddressAdapter.pin({timeout: 3}, '203.0.113.1')

      assert_equal(PinnedAddressAdapter, options[:connection_adapter])
      assert_equal('203.0.113.1', options.dig(:connection_adapter_options, :pinned_address))
      assert_equal(3, options[:timeout])
    end

    def test_pin_address_is_noop_without_address
      assert_equal({timeout: 3}, PinnedAddressAdapter.pin({timeout: 3}, nil))
    end

    # ⚠ 真偽値を返す従来の validator の戻りをそのまま渡されても pinning しない
    # （`ipaddr = true` を差すと接続時に落ちる）。
    def test_pin_address_ignores_non_string
      assert_equal({timeout: 3}, PinnedAddressAdapter.pin({timeout: 3}, true))
    end

    # 実際に Net::HTTP の接続先が差し替わること。⚠ Host ヘッダと TLS の
    # SNI・証明書検証はホスト名のままでなければならない（IP で検証すると
    # HTTPS が全滅する）。
    def test_adapter_pins_ipaddr_without_changing_host
      connection = PinnedAddressAdapter.call(
        ::URI.parse('https://example.com/exec'),
        {connection_adapter_options: {pinned_address: '203.0.113.1'}},
      )

      assert_equal('203.0.113.1', connection.ipaddr)
      assert_equal('example.com', connection.address)
      assert_true(connection.use_ssl?)
    end

    def test_adapter_without_pinned_address_keeps_default
      connection = PinnedAddressAdapter.call(::URI.parse('https://example.com/exec'), {})

      assert_nil(connection.ipaddr)
      assert_equal('example.com', connection.address)
    end

    # ⚠ **プロキシ経由では pinning が効かない**（接続先はプロキシで、名前を
    # 解決するのもプロキシ）。素通りさせるくらいなら落とす。
    def test_adapter_refuses_to_pin_through_explicit_proxy
      error = assert_raise(PinningError) do
        PinnedAddressAdapter.call(::URI.parse('http://example.com/exec'), {
          http_proxyaddr: 'proxy.example',
          http_proxyport: 8080,
          connection_adapter_options: {pinned_address: '203.0.113.1'},
        })
      end

      assert_match(/Cannot pin/, error.message)
    end

    # ⚠ Net::HTTP.new の proxy 引数は既定が :ENV。明示していなくても
    # http_proxy を置いた環境では proxy? が true になる。
    #
    # 🔴 **宛先に実在する名前を使わないこと (#616)。** `URI#find_proxy` は
    # **宛先がループバックへ解決されると proxy を返さない**ので、`example.com` を
    # `127.0.0.1` へ潰す環境（サンドボックス・社内 DNS）では `proxy?` が false に
    # なり、**このテストだけが常に赤くなる**。⚠⚠ CI のコンテナは実アドレスへ
    # 解決するので**緑のまま**で、手元だけが落ちる ＝ 一番たちが悪い形。
    #
    # ⚠ `.invalid` は RFC 6761 で**解決されないことが保証された TLD**。
    # `getaddress` が SocketError を上げ、`find_proxy` はそれを rescue して
    # proxy を返すので、**どの環境でも同じ結果になる**（実測）。
    def test_adapter_refuses_to_pin_through_env_proxy
      saved = ENV.fetch('http_proxy', nil)
      ENV['http_proxy'] = 'http://proxy.example:8080'
      begin
        assert_raise(PinningError) do
          PinnedAddressAdapter.call(::URI.parse('http://pinning.invalid/exec'), {
            connection_adapter_options: {pinned_address: '203.0.113.1'},
          })
        end
      ensure
        saved.nil? ? ENV.delete('http_proxy') : ENV['http_proxy'] = saved
      end
    end

    # ⚠ **pinning できないことを再送で解決しようとしない。**プロキシ設定は試行の
    # 間に変わらないのに、GatewayError のままだと source_status が 502 で
    # 「上流の一時障害」と読まれ、既定で 5 回叩き直して 4 秒眠る。
    def test_pinning_error_is_not_retryable
      assert_false(@http.send(:retryable?, PinningError.new('Cannot pin')))
      assert_true(@http.send(:retryable?, GatewayError.new('Bad response 503')))
    end

    # ⚠ 宛先が `.invalid` なのは上と同じ理由 (#616)。
    def test_get_does_not_retry_proxy_rejection
      saved = ENV.fetch('http_proxy', nil)
      ENV['http_proxy'] = 'http://proxy.example:8080'
      begin
        assert_raise(PinningError) do
          @http.get('http://pinning.invalid/exec', host_validator: ->(_host) {'203.0.113.1'})
        end
      ensure
        saved.nil? ? ENV.delete('http_proxy') : ENV['http_proxy'] = saved
      end

      assert_not_requested(:get, 'http://pinning.invalid/exec')
    end

    # ------------------------------------------------------------------
    # #527: リダイレクト追従時に初段の query と資格情報を撃ち直していた
    # ------------------------------------------------------------------

    # ⚠⚠ **初段のクエリを次のホップへ持ち越さない。** Location はクエリまで
    # 含めて次に撃つ先を指しているので、初段の分を足すと **Location が求めても
    # いないパラメータが付いて回る**。そこに秘密が入っていれば別ホストへ渡る。
    def test_drops_initial_query_on_redirect
      WebMock.stub_request(:get, 'https://a.example/exec').with(query: {'token' => 'secret'})
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      response = @http.get(
        'https://a.example/exec',
        query: {token: 'secret'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_equal('ok', response.body)
      assert_not_requested(:get, 'https://b.example/echo', query: {'token' => 'secret'})
    end

    # 同じオリジンの中でも撃ち直さない。Location が正。
    def test_drops_initial_query_on_same_origin_redirect
      WebMock.stub_request(:get, 'https://a.example/exec').with(query: {'token' => 'secret'})
        .to_return(status: 302, headers: {'Location' => '/echo'})
      WebMock.stub_request(:get, 'https://a.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        query: {token: 'secret'},
        host_validator: public_hosts('a.example'),
      )

      assert_not_requested(:get, 'https://a.example/echo', query: {'token' => 'secret'})
    end

    # ⚠ 落とすのは**初段の** query であって、Location 自身が持つクエリは残す。
    def test_keeps_query_carried_by_location
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo?sig=abc'})
      WebMock.stub_request(:get, 'https://b.example/echo').with(query: {'sig' => 'abc'})
        .to_return(status: 200, body: 'ok')

      response = @http.get('https://a.example/exec', host_validator: public_hosts('a.example', 'b.example'))

      assert_equal('ok', response.body)
    end

    # ⚠⚠ **本丸。** `Authorization` / `Cookie` はオリジンに紐づく。
    # host_validator が「公開ホストか」しか見ない実装だと、**リダイレクト先が
    # 公開ホストでありさえすれば通る**ので、この経路は validator では塞げない。
    def test_drops_credentials_on_cross_origin_redirect
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        headers: {'Authorization' => 'Bearer secret', 'Cookie' => 'session=secret', 'X-Trace' => 'keep'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:get, 'https://a.example/exec') do |req|
        req.headers['Authorization'] == 'Bearer secret'
      end
      assert_requested(:get, 'https://b.example/echo') do |req|
        req.headers['Authorization'].nil? && req.headers['Cookie'].nil? && req.headers['X-Trace'] == 'keep'
      end
    end

    # ⚠ ヘッダ名の大小は当てにできない。呼び出し側は素の hash を渡してくる。
    def test_drops_credentials_regardless_of_header_case
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        headers: {'authorization' => 'Bearer secret'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:get, 'https://b.example/echo') {|req| req.headers['Authorization'].nil?}
    end

    # 同一オリジンの中では落とす必要が無い。落とすと普通の認証付き取得が壊れる。
    def test_keeps_credentials_on_same_origin_redirect
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => '/echo'})
      WebMock.stub_request(:get, 'https://a.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        headers: {'Authorization' => 'Bearer secret'},
        host_validator: public_hosts('a.example'),
      )

      assert_requested(:get, 'https://a.example/echo') do |req|
        req.headers['Authorization'] == 'Bearer secret'
      end
    end

    # ⚠ 既定ポートを明示しただけでは別オリジンではない。ここを取り違えると
    # 資格情報が無駄に落ちる。
    def test_keeps_credentials_when_only_default_port_is_explicit
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://a.example:443/echo'})
      WebMock.stub_request(:get, 'https://a.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        headers: {'Authorization' => 'Bearer secret'},
        host_validator: public_hosts('a.example'),
      )

      assert_requested(:get, 'https://a.example/echo') do |req|
        req.headers['Authorization'] == 'Bearer secret'
      end
    end

    # ⚠ **https → http の格下げも別オリジン。** ホストが同じでも平文へ落ちる。
    def test_drops_credentials_on_scheme_downgrade
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'http://a.example/echo'})
      WebMock.stub_request(:get, 'http://a.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        headers: {'Authorization' => 'Bearer secret'},
        host_validator: public_hosts('a.example'),
      )

      assert_requested(:get, 'http://a.example/echo') {|req| req.headers['Authorization'].nil?}
    end

    # ⚠⚠ **一度落ちたら戻らない。** `A → B → A` と戻ってきても復活させない。
    # 戻せる作りにすると、B が「A へ戻す」だけで資格情報を引き出せてしまう。
    def test_credentials_stay_dropped_after_returning_to_the_first_origin
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/hop'})
      WebMock.stub_request(:get, 'https://b.example/hop')
        .to_return(status: 302, headers: {'Location' => 'https://a.example/echo'})
      WebMock.stub_request(:get, 'https://a.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        headers: {'Authorization' => 'Bearer secret'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:get, 'https://a.example/echo') {|req| req.headers['Authorization'].nil?}
    end

    # ⚠ 呼び出し側の hash を壊さない (#528 / #537 と同じ不変条件)。ここで
    # 資格情報を落とすようになったので、呼び出し側の headers から消えていない
    # ことを見ておく。
    def test_dropping_credentials_does_not_pollute_caller_headers
      WebMock.stub_request(:get, 'https://a.example/exec').with(query: {'token' => 'secret'})
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')
      headers = {'Authorization' => 'Bearer secret'}
      options = {headers:, query: {token: 'secret'}, host_validator: public_hosts('a.example', 'b.example')}

      @http.get('https://a.example/exec', options)

      assert_equal({'Authorization' => 'Bearer secret'}, headers)
      assert_equal({token: 'secret'}, options[:query])
    end

    # ------------------------------------------------------------------
    # #568: 資格情報がヘッダ経由とは限らない
    # ------------------------------------------------------------------

    # ⚠⚠ **本丸。** HTTParty の `basic_auth:` はヘッダではなく options で渡る。
    # `headers` が空だと以前はここで早期 return しており、**リダイレクト先へ
    # Basic 認証をそのまま撃ち直していた**。
    #
    # 🔴 HTTParty 自身の抑止（ホストが変わったら送らない）は、**1 つの Request が
    # ホップを追うとき**にしか働かない。ここはホップごとに Request を作り直すので
    # 効かない。
    def test_drops_basic_auth_on_cross_origin_redirect
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        basic_auth: {username: 'user', password: 'secret'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:get, 'https://a.example/exec') do |req|
        req.headers['Authorization'] == "Basic #{['user:secret'].pack('m0')}"
      end
      assert_requested(:get, 'https://b.example/echo') {|req| req.headers['Authorization'].nil?}
    end

    # ⚠ ヘッダが空でないときも落ちること。`headers.blank?` の早期 return だけの
    # 話ではなく、**資格情報オプションを落とす経路がそもそも無かった**。
    def test_drops_basic_auth_even_when_headers_are_present
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        headers: {'X-Trace' => 'keep'},
        basic_auth: {username: 'user', password: 'secret'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:get, 'https://b.example/echo') do |req|
        req.headers['Authorization'].nil? && req.headers['X-Trace'] == 'keep'
      end
    end

    # ⚠⚠ **`cookies:` も options 経由の資格情報 (#576)。**`Cookie` ヘッダ自体は
    # CREDENTIAL_HEADERS で落ちるが、HTTParty は**呼び出しごとに**
    # `options[:cookies]` を headers へ移すので、こちらが持ち回る options には
    # 残ったままになり、**ヘッダを見る判定に一度も掛からない**。
    def test_drops_cookies_option_on_cross_origin_redirect
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        cookies: {session: 'SECRET'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:get, 'https://a.example/exec') {|req| req.headers['Cookie'] == 'session=SECRET'}
      assert_requested(:get, 'https://b.example/echo') {|req| req.headers['Cookie'].nil?}
    end

    # 同一オリジンでは落とさない。セッション付きの取得が壊れる。
    def test_keeps_cookies_option_on_same_origin_redirect
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => '/echo'})
      WebMock.stub_request(:get, 'https://a.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        cookies: {session: 'SECRET'},
        host_validator: public_hosts('a.example'),
      )

      assert_requested(:get, 'https://a.example/echo') {|req| req.headers['Cookie'] == 'session=SECRET'}
    end

    # 同一オリジンでは落とさない。落とすと普通の Basic 認証付き取得が壊れる。
    def test_keeps_basic_auth_on_same_origin_redirect
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => '/echo'})
      WebMock.stub_request(:get, 'https://a.example/echo').to_return(status: 200, body: 'ok')

      @http.get(
        'https://a.example/exec',
        basic_auth: {username: 'user', password: 'secret'},
        host_validator: public_hosts('a.example'),
      )

      assert_requested(:get, 'https://a.example/echo') do |req|
        req.headers['Authorization'] == "Basic #{['user:secret'].pack('m0')}"
      end
    end

    # ⚠ `digest_auth` は 401 チャレンジを受けて初めて撃つので、リダイレクトだけの
    # 経路では再現できない。落ちることは redirect_options で直接見る。
    # ⚠⚠ **上流には digest 向けの抑止が無い**ので、こちらで落とさないと残る。
    def test_drops_credential_options_on_cross_origin_redirect
      options = @http.send(
        :redirect_options,
        {digest_auth: {username: 'user', password: 'secret'}, headers: {'X-Trace' => 'keep'}},
        @http.send(:origin_of, URI.parse('https://a.example/exec')),
        URI.parse('https://b.example/echo'),
      )

      assert_equal({headers: {'X-Trace' => 'keep'}}, options)
    end

    # ⚠ **クライアント証明書は落とさない。** 秘密鍵は出て行かず、提示先は
    # `validate_host!` を通ったホストなので、落としても防げるものが無い。
    def test_keeps_client_certificate_options_on_cross_origin_redirect
      options = @http.send(
        :redirect_options,
        {pem: 'PEM', pem_password: 'secret', basic_auth: {username: 'u', password: 'p'}},
        @http.send(:origin_of, URI.parse('https://a.example/exec')),
        URI.parse('https://b.example/echo'),
      )

      assert_equal({pem: 'PEM', pem_password: 'secret'}, options)
    end

    # ⚠ 呼び出し側の hash を壊さない (#528 / #537 / #527 と同じ不変条件)。
    def test_dropping_credential_options_does_not_pollute_caller_options
      WebMock.stub_request(:get, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')
      basic_auth = {username: 'user', password: 'secret'}
      options = {basic_auth:, host_validator: public_hosts('a.example', 'b.example')}

      @http.get('https://a.example/exec', options)

      assert_equal({username: 'user', password: 'secret'}, basic_auth)
      assert_equal(basic_auth, options[:basic_auth])
    end

    # ------------------------------------------------------------------
    # #569: body を伴うメソッドが host_validator を黙って無視していた
    # ------------------------------------------------------------------

    # 🔴 **本丸。** `request_with_body` には validator の分岐が無く、
    # `options[:host_validator]` は HTTParty へ知らないオプションとして渡って
    # 捨てられていた。⚠⚠ `follow_redirects` は既定の true のままなので、
    # **初段すら検証せずリダイレクトを追い、リンクローカルまで到達していた。**
    def test_post_validates_every_hop
      WebMock.stub_request(:post, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'http://169.254.169.254/latest/meta-data/'})

      error = assert_raise(GatewayError) do
        @http.post('https://a.example/exec', body: {}, host_validator: public_hosts('a.example'))
      end

      assert_match(/Rejected host/, error.message)
      assert_not_requested(:get, 'http://169.254.169.254/latest/meta-data/')
    end

    # ⚠ 「拒否されなかった」のではなく「一度も検証していなかった」。初段が
    # validator を通ることを、渡されたホスト名そのもので見る。
    def test_post_validates_first_hop
      WebMock.stub_request(:post, 'https://a.example/exec').to_return(status: 200, body: 'ok')
      hosts = []

      @http.post('https://a.example/exec', body: {}, host_validator: ->(host) {hosts.push(host) && true})

      assert_equal(['a.example'], hosts)
    end

    def test_put_and_delete_validate_hops
      [:put, :delete].each do |method|
        WebMock.reset!
        WebMock.stub_request(method, 'https://a.example/exec')
          .to_return(status: 302, headers: {'Location' => 'http://169.254.169.254/meta'})

        assert_raise(GatewayError) do
          @http.public_send(method, 'https://a.example/exec', body: {}, host_validator: public_hosts('a.example'))
        end

        assert_not_requested(:get, 'http://169.254.169.254/meta')
      end
    end

    # ⚠⚠ **302 では POST が GET に化け、body が落ちる。** これは HTTParty の
    # `handle_redirection` と同じ規則で、**validator を足したせいで結果が
    # 変わってはいけない**。
    def test_post_becomes_get_on_found_redirect
      WebMock.stub_request(:post, 'https://a.example/exec')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:get, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      @http.post(
        'https://a.example/exec',
        body: {token: 'secret'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:get, 'https://b.example/echo') {|req| req.body.nil? || req.body.empty?}
    end

    # ⚠⚠ **307 / 308 はメソッドごと保つ。** ここで body を落とすと、
    # **空の POST を撃つ**ことになる。
    def test_post_keeps_method_and_body_on_temporary_redirect
      WebMock.stub_request(:post, 'https://a.example/exec')
        .to_return(status: 307, headers: {'Location' => 'https://b.example/echo'})
      WebMock.stub_request(:post, 'https://b.example/echo').to_return(status: 200, body: 'ok')

      @http.post(
        'https://a.example/exec',
        body: {token: 'secret'},
        host_validator: public_hosts('a.example', 'b.example'),
      )

      assert_requested(:post, 'https://b.example/echo') {|req| req.body == {token: 'secret'}.to_json}
    end

    # validator を渡さない従来の呼び出しは HTTParty のまま。
    def test_post_without_validator_keeps_httparty_behavior
      WebMock.stub_request(:post, 'https://example.com/exec')
        .to_return(status: 302, headers: {'Location' => 'https://example.com/echo'})
      WebMock.stub_request(:get, 'https://example.com/echo').to_return(status: 200, body: 'ok')

      assert_equal('ok', @http.post('https://example.com/exec', body: {}).body)
    end

    # ⚠ 呼び出し側の hash を壊さない (#528 と同じ不変条件)。GET / HEAD の経路は
    # 直っていたが、こちらは分岐そのものが無かったので今回が初めて。
    def test_post_does_not_pollute_caller_options
      WebMock.stub_request(:post, 'https://a.example/exec').to_return(status: 200, body: 'ok')
      options = {body: {}, host_validator: public_hosts('a.example')}

      @http.post('https://a.example/exec', options)
      @http.post('https://a.example/exec', options)

      assert_equal([:body, :host_validator], options.keys)
      assert_requested(:post, 'https://a.example/exec', times: 2)
    end

    # ⚠ `upload` も同じ穴だった。利用側は「あれはリクエストパラメータの hash
    # だから」と解釈して自分で delete していた (mulukhiya-toot-proxy#4576) —
    # **渡せてしまうのに効かない**ので、そう読むほかなかった。
    def test_upload_validates_hops
      WebMock.stub_request(:post, 'https://a.example/up')
        .to_return(status: 302, headers: {'Location' => 'http://169.254.169.254/meta'})

      Tempfile.create('probe') do |f|
        f.write('CONTENTS')
        f.flush
        f.rewind

        assert_raise(GatewayError) do
          @http.upload('https://a.example/up', f, host_validator: public_hosts('a.example'))
        end
      end

      assert_not_requested(:get, 'http://169.254.169.254/meta')
    end

    # 307 の撃ち直しでも本文が揃っていること。
    #
    # ⚠⚠ **このテストは `rewind_body!` を押さえていない (#603)。** 外しても緑の
    # まま通る（実測: 53 tests / 0 failures）— **実際に巻き戻しているのは
    # HTTParty** だから。⚠ ここで見ているのは「撃ち直しの本文が空でない」という
    # 外から見える性質だけで、**誰が巻き戻したかは問わない**。
    # `rewind_body!` そのものは `test_redirect_options_rewinds_body` が押さえる。
    def test_upload_rewinds_file_on_temporary_redirect
      WebMock.stub_request(:post, 'https://a.example/up')
        .to_return(status: 307, headers: {'Location' => 'https://b.example/up'})
      WebMock.stub_request(:post, 'https://b.example/up').to_return(status: 200, body: 'ok')

      Tempfile.create('probe') do |f|
        f.write('CONTENTS')
        f.flush
        f.rewind

        @http.upload('https://a.example/up', f, host_validator: public_hosts('a.example', 'b.example'))
      end

      assert_requested(:post, 'https://b.example/up') {|req| req.body.include?('CONTENTS')}
    end

    # 🔴 **撃ち直す前に body の IO を巻き戻すこと (#603)。**
    #
    # ⚠⚠ **出力では測れない。** HTTParty も自分で巻き戻すので、「撃ち直した本文が
    # 空でない」を見るテストは `rewind_body!` を外しても緑のまま通る。⚠ ここで
    # 押さえるのは `redirect_options` の契約そのもの — **上流が巻き戻しを止めた
    # 日に、こちらが黙って空の本文を送らない**ための行。
    def test_redirect_options_rewinds_body
      probe = StringIO.new('CONTENTS')
      probe.read
      uri = @http.send(:create_uri, 'https://a.example/up')

      options = @http.send(
        :redirect_options,
        {body: {file: probe}},
        @http.send(:origin_of, uri),
        uri,
        keep_body: true,
      )

      assert_equal(0, probe.pos, '撃ち直す前に先頭へ戻すこと')
      assert_same(probe, options.dig(:body, :file), 'body そのものは差し替えないこと')
    end

    # ⚠ メソッドごと変わるリダイレクト（303 など）では body を落とす。巻き戻す
    # 相手も無い。
    def test_redirect_options_drops_body_unless_method_is_kept
      probe = StringIO.new('CONTENTS')
      probe.read
      uri = @http.send(:create_uri, 'https://a.example/up')

      options = @http.send(
        :redirect_options,
        {body: {file: probe}},
        @http.send(:origin_of, uri),
        uri,
        keep_body: false,
      )

      assert_not_include(options, :body)
      assert_equal(8, probe.pos, '落とす body は巻き戻さないこと')
    end

    # ⚠⚠ **304 はリダイレクトではない。** 3xx に入っているので `between?` だけ
    # だと拾ってしまう。🔴 HTTParty は `Net::HTTPNotModified` を除いているので、
    # **validator を渡したときだけ Location 付きの 304 を追っていた**。
    def test_does_not_follow_not_modified
      WebMock.stub_request(:get, 'https://a.example/x')
        .to_return(status: 304, headers: {'Location' => 'https://b.example/y'})
      WebMock.stub_request(:get, 'https://b.example/y').to_return(status: 200, body: 'FOLLOWED')

      response = @http.get('https://a.example/x', host_validator: public_hosts('a.example', 'b.example'))

      assert_equal(304, response.code)
      assert_not_requested(:get, 'https://b.example/y')
    end

    # プロキシがあっても pinning を要求していなければ従来どおり通す。
    def test_adapter_allows_proxy_without_pinning
      connection = PinnedAddressAdapter.call(::URI.parse('http://example.com/exec'), {
        http_proxyaddr: 'proxy.example',
        http_proxyport: 8080,
      })

      assert_true(connection.proxy?)
      assert_nil(connection.ipaddr)
    end

    # pinning を有効にしたホップでもリクエスト自体は通ること。
    def test_get_with_pinning_validator_succeeds
      WebMock.stub_request(:get, 'https://example.com/exec').to_return(status: 200, body: 'ok')

      response = @http.get('https://example.com/exec', host_validator: ->(_host) {'203.0.113.1'})

      assert_equal('ok', response.body)
    end
  end
end
