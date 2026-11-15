# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # host_validator が通さなかったときの、例外の型・ログの行・validator が受け取るもの (#695)。
  # ⚠ DNS は引かない（`PublicHost.resolve_addresses` を差し替える）。
  class HTTPHostRejectionTest < TestCase
    def setup
      @http = HTTP.new
      WebMock.disable_net_connect!
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    # --- PublicHost: 拒否と「解決できない」を分ける

    def test_public_host_raises_resolution_error_on_empty
      error = assert_raise(HostResolutionError) do
        PublicHost.resolved_address('example.com', resolver: ->(_) {[]})
      end

      assert_true(error.message.start_with?("Rejected host 'example.com'"))
    end

    def test_public_host_raises_resolution_error_on_resolver_failure
      [Resolv::ResolvError, Timeout::Error, SocketError, Errno::EMFILE].each do |klass|
        error = assert_raise(HostResolutionError, klass.name) do
          PublicHost.resolved_address('example.com', resolver: ->(_) {raise klass})
        end

        assert_kind_of(klass, error.cause)
        assert_include(error.message, klass.name)
      end
    end

    # ⚠ 内部アドレス・形の壊れた名前は「解決できない」ではなく拒否（nil）。
    def test_public_host_rejection_is_not_resolution_error
      assert_nil(PublicHost.resolved_address('example.com', resolver: ->(_) {['10.0.0.1']}))
      assert_nil(PublicHost.resolved_address('localhost', resolver: ->(_) {raise 'must not resolve'}))
      assert_nil(PublicHost.resolved_address('127.0.0.1', resolver: ->(_) {raise 'must not resolve'}))
    end

    # ⚠ 真偽だけが要る呼び方は従来どおり（mulukhiya-toot-proxy の `RemoteHost` が使う）。
    def test_allowed_address_keeps_nil_on_resolution_failure
      assert_nil(PublicHost.allowed_address('example.com', resolver: ->(_) {[]}))
      assert_nil(PublicHost.allowed_address('example.com', resolver: ->(_) {raise Resolv::ResolvError}))
      assert_false(PublicHost.public?('example.com', resolver: ->(_) {[]}))
    end

    def test_public_host_validator_raises_resolution_error
      with_resolver(->(*) {[]}) do
        assert_raise(HostResolutionError) {PublicHost.validator.call('example.com')}
      end
      with_resolver(->(*) {['93.184.215.14']}) do
        assert_equal('93.184.215.14', PublicHost.validator.call('example.com'))
      end
    end

    # --- HTTP: 例外の型と、行

    def test_unresolvable_host_reaches_http_as_resolution_error
      stub = WebMock.stub_request(:get, 'https://example.com/feed')
      logged = error_log
      error = with_resolver(->(*) {raise Timeout::Error}) do
        assert_raise(HostResolutionError) do
          @http.get('https://example.com/feed', host_validator: PublicHost.validator)
        end
      end

      assert_true(error.message.start_with?("Rejected host 'example.com'"))
      assert_kind_of(GatewayError, error)
      assert_not_requested(stub)
      assert_equal([:unresolvable_host], logged.map {|v| v[:gave_up]})
    end

    def test_rejection_leaves_an_error_line
      logged = capture_error_log do
        assert_raise(RejectedHostError) do
          @http.get('https://internal.example/a?token=SECRET', host_validator: ->(_host) {false})
        end
      end

      assert_equal(1, logged.size)
      assert_equal(:rejected_host, logged.first[:gave_up])
      assert_equal(:GET, logged.first[:method])
      assert_include(logged.first[:url], 'internal.example/a')
      assert_instance_of(RejectedHostError, logged.first[:error])
    end

    # ⚠ 2 段目以降の行はクエリを落とした形（`hop_log_uri`・#717）。拒否した先の URL も残る。
    def test_rejection_on_redirect_logs_the_rejected_hop
      WebMock.stub_request(:get, 'https://a.example/start')
        .to_return(status: 302, headers: {'Location' => 'https://b.example/next?code=SECRET'})
      logged = capture_error_log do
        assert_raise(RejectedHostError) do
          @http.get('https://a.example/start', host_validator: ->(host) {host == 'a.example'})
        end
      end
      rejected = logged.select {|v| v[:gave_up] == :rejected_host}

      assert_equal(1, rejected.size)
      assert_equal('https://b.example/next', rejected.first[:url])
    end

    # ⚠ validator の不具合（`RejectedHostError` 以外）は握らず、行も足さない。
    def test_validator_bug_is_not_swallowed
      logged = capture_error_log do
        assert_raise(ZeroDivisionError) do
          @http.get('https://a.example/', host_validator: ->(_host) {1 / 0})
        end
      end

      assert_equal([], logged)
    end

    # --- validator が URI を受け取る口

    def test_validator_with_uri_keyword_receives_the_hop_uri
      WebMock.stub_request(:get, 'https://a.example/start')
        .to_return(status: 302, headers: {'Location' => 'http://a.example:8080/next'})
      seen = []
      validator = lambda do |host, uri:|
        seen.push([host, uri.scheme, uri.inferred_port])
        next uri.scheme == 'https'
      end

      assert_raise(RejectedHostError) {@http.get('https://a.example/start', host_validator: validator)}
      assert_equal([['a.example', 'https', 443], ['a.example', 'http', 8080]], seen)
    end

    def test_validator_with_optional_uri_keyword
      WebMock.stub_request(:get, 'https://a.example:8443/')
      seen = []
      validator = ->(_host, uri: nil) {seen.push(uri&.inferred_port)}

      @http.get('https://a.example:8443/', host_validator: validator)

      assert_equal([8443], seen)
    end

    # ⚠ `call` を持つオブジェクト（lambda でない validator）も同じ判定。
    def test_callable_object_with_uri_keyword
      WebMock.stub_request(:get, 'https://a.example/')
      validator = Class.new do
        attr_reader :seen

        def call(_host, uri:)
          (@seen ||= []).push(uri.path)
          return true
        end
      end.new

      @http.get('https://a.example/', host_validator: validator)

      assert_equal(['/'], validator.seen)
    end

    # ⚠ 既存の形（ホスト名 1 つ）と `**opts` は、ホスト名だけを受ける。
    def test_validator_without_uri_keyword_gets_host_only
      WebMock.stub_request(:get, 'https://a.example/')
      seen = []

      @http.get('https://a.example/', host_validator: ->(host) {seen.push(host)})
      @http.get('https://a.example/', host_validator: ->(host, **opts) {seen.push([host, opts])})
      @http.get('https://a.example/', host_validator: proc {|host| seen.push(host)})

      assert_equal(['a.example', ['a.example', {}], 'a.example'], seen)
    end

    # ⚠ 渡すのは複製。validator が書き換えても、要求の先は変わらない。
    def test_validator_cannot_redirect_the_request
      stub = WebMock.stub_request(:get, 'https://a.example/')
      validator = lambda do |_host, uri:|
        uri.host = 'evil.example'
        next true
      end

      @http.get('https://a.example/', host_validator: validator)

      assert_requested(stub)
    end

    private

    def capture_error_log
      logged = error_log
      yield
      return logged
    end

    def error_log
      logged = []
      @http.instance_variable_get(:@logger).define_singleton_method(:error) {|entry| logged.push(entry)}
      return logged
    end

    def with_resolver(resolver)
      original = PublicHost.method(:resolve_addresses)
      PublicHost.define_singleton_method(:resolve_addresses) {|*args, **kwargs| resolver.call(*args, **kwargs)}
      return yield
    ensure
      PublicHost.define_singleton_method(:resolve_addresses, original)
    end
  end
end
