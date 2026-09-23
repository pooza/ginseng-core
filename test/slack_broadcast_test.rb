# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # 🔴🔴 **1 本の hook の失敗で、残りのアラートを止めないこと (#653)。**
  #
  # ⚠⚠ `RedirectGuard` が入って 3xx が例外になったので、**`http://` のまま登録された
  # hook が 1 本あるだけで以降のアラートが 1 通も出なくなる**という退行が生まれていた
  # （リリース前レビューの観点②で実測）。⚠ それまでは 301 を GET に化けさせて追い、
  # **本文を落としたまま成功を返していた** — つまり元から送れてはいなかった。
  class SlackBroadcastTest < TestCase
    FIRST = 'http://hooks.example.com/T1'
    SECOND = 'https://hooks.example.com/T2'
    MOVED = 'https://hooks.example.com/moved'

    # 🔴🔴 **`Config.instance` を書き換えない。** `Config#reload` は書いたキーを
    # 消さない（`load` は `@raw` を見て merge するだけ）ので、**シングルトンに残って
    # 他のテストの前提を壊す** — 実測で `/slack/hooks` を書いたら
    # `SlackTest#disable?` が false になり、本物の Slack へ送ろうとして 2 件 error に
    # なった。⚠ 宛先は `all` の差し替えで渡す。
    class StubSlack < Slack
      def self.all(&block)
        return enum_for(__method__) unless block
        [FIRST, SECOND].map {|uri| StubSlack.new(uri)}.each(&block)
      end
    end

    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      return if disable?
      WebMock.disable_net_connect!
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def test_broadcast_reaches_every_hook_even_if_one_redirects
      stub_request(:post, FIRST).to_return(status: 301, headers: {'Location' => MOVED})
      stub_request(:post, MOVED).to_return(status: 200)
      second = stub_request(:post, SECOND).to_return(status: 200)

      # ⚠ 失敗は飲まない。全部撃ったあとで上げ直す。
      assert_raise(GatewayError) {StubSlack.broadcast(message: 'OK')}
      assert_requested(second)
      # ⚠⚠ リダイレクト先へは行かない（ガードが効いている）。
      assert_not_requested(:post, MOVED)
    end

    def test_broadcast_raises_nothing_when_every_hook_is_fine
      stub_request(:post, FIRST).to_return(status: 200)
      stub_request(:post, SECOND).to_return(status: 200)

      assert_nil(StubSlack.broadcast(message: 'OK'))
    end
  end
end
