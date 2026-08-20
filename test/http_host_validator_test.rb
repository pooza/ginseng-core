# frozen_string_literal: true

require 'webmock/test_unit'

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
    def test_adapter_refuses_to_pin_through_env_proxy
      saved = ENV.fetch('http_proxy', nil)
      ENV['http_proxy'] = 'http://proxy.example:8080'
      begin
        assert_raise(PinningError) do
          PinnedAddressAdapter.call(::URI.parse('http://example.com/exec'), {
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

    def test_get_does_not_retry_proxy_rejection
      saved = ENV.fetch('http_proxy', nil)
      ENV['http_proxy'] = 'http://proxy.example:8080'
      begin
        assert_raise(PinningError) do
          @http.get('http://example.com/exec', host_validator: ->(_host) {'203.0.113.1'})
        end
      ensure
        saved.nil? ? ENV.delete('http_proxy') : ENV['http_proxy'] = saved
      end

      assert_not_requested(:get, 'http://example.com/exec')
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
