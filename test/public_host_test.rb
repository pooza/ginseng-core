# frozen_string_literal: true

module Ginseng
  # 公開アドレスだけを通す判定 (#660)。⚠ DNS は引かず、resolver を差し替えて測る。
  class PublicHostTest < TestCase
    def test_public_address_is_returned_for_pinning
      assert_equal('93.184.215.14', allowed('example.com', ['93.184.215.14']))
    end

    def test_internal_addresses_are_rejected
      internals = [
        '127.0.0.1', '10.0.0.1', '172.16.0.1', '192.168.1.1', '169.254.169.254',
        '0.0.0.0', '100.64.0.1', '::1', 'fe80::1', 'fc00::1', 'fec0::1', '::', '::ffff:127.0.0.1'
      ]

      internals.each {|ip| assert_nil(allowed('example.com', [ip]), ip)}
    end

    # ⚠⚠ **1 本でも内部アドレスを含めば拒否**（混ぜて返すのはリバインディングそのもの）。
    def test_mixed_answers_are_rejected
      assert_nil(allowed('example.com', ['93.184.215.14', '127.0.0.1']))
    end

    def test_ipv4_is_preferred
      assert_equal('93.184.215.14', allowed('example.com', ['2606:2800:21f:cb07:6820:80da:af6b:8b2c', '93.184.215.14']))
    end

    def test_literals_and_single_labels_are_rejected
      ['169.254.169.254', '[::1]', 'localhost', ''].each do |host|
        assert_nil(allowed(host, ['93.184.215.14']), host)
      end
    end

    # ⚠ 解決できない・失敗したら拒否（fail-closed）。
    def test_resolution_failures_are_rejected
      assert_nil(allowed('example.com', []))
      assert_nil(PublicHost.allowed_address('example.com', resolver: ->(_) {raise Resolv::ResolvError}))
    end

    # 🔴🔴 **締め切りは解決全体に掛かること (pooza/ginseng-web#140 Codex P1)。** 応答しないネームサーバーを
    # 3 台並べると、問い合わせごとの timeout だけでは 2 種別 × 3 台 × 3 秒 = 18 秒かかる。
    # ⚠ 192.0.2.0/24（TEST-NET-1）は経路が無く、応答が返らない。
    def test_resolution_has_a_single_deadline
      stalled = ['192.0.2.1', '192.0.2.2', '192.0.2.3']
      started = Time.now
      resolver = ->(host) {PublicHost.resolve_addresses(host, nameserver: stalled)}

      assert_nil(PublicHost.allowed_address('img.example.com', resolver:))
      assert_operator(Time.now - started, :<, PublicHost::DNS_TIMEOUT + 1)
    end

    def test_public_predicate
      assert_true(PublicHost.public?('example.com', resolver: ->(_) {['93.184.215.14']}))
      assert_false(PublicHost.public?('example.com', resolver: ->(_) {['10.0.0.1']}))
      assert_false(PublicHost.public?('localhost', resolver: ->(_) {['93.184.215.14']}))
    end

    # 🔴 **受け口まで通すこと。** `HTTP` は validator が返した IP へ接続を固定し、
    # 拒否（nil）なら要求を出さない。
    def test_validator_is_accepted_by_http
      validator = PublicHost.validator

      assert_respond_to(validator, :call)
      assert_nil(validator.call('localhost'))
      assert_nil(validator.call('127.0.0.1'))
      assert_raise(GatewayError) {HTTP.new.get('http://127.0.0.1/', {host_validator: validator})}
    end

    private

    def allowed(host, addrs)
      return PublicHost.allowed_address(host, resolver: ->(_) {addrs})
    end
  end
end
