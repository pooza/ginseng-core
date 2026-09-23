# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # 資格情報を運ぶ要求のリダイレクトの扱い (#653)。
  #
  # ⚠⚠ **options の中身ではなく、2 段目へ実際に届くかを見る。** `follow_redirects: false`
  # が入っていることを確かめるだけでは、**HTTParty がそれを尊重しているか**を測って
  # いない（`upload` は渡した options を組み直すので、実際に効いていない経路がある）。
  class HTTPRedirectGuardTest < TestCase
    ORIGIN = 'https://example.com'
    ELSEWHERE = 'https://elsewhere.example.com/moved'

    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      return if disable?
      WebMock.disable_net_connect!
      @url = "#{ORIGIN}/api"
      @http = HTTP.new.guard_redirects!
      @http.base_uri = ORIGIN
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def redirect(method, status, location = ELSEWHERE)
      stub_request(method, @url).to_return(status:, headers: {'Location' => location})
      return stub_request(method, location).to_return(status: 200, body: '2 段目')
    end

    # 🔴🔴 **本件の芯。** 307 / 308 は本文ごと別ホストへ撃ち直されるので、資格情報を
    # 持つ書き込みは 2 段目へ 1 度も届いてはならない。
    def test_credentialed_post_never_reaches_the_second_hop
      redirect(:post, 307)

      assert_raise(GatewayError) do
        @http.post('/api', {body: {status: '本文'}, headers: {'Authorization' => 'Bearer secret'}})
      end
      assert_not_requested(:post, ELSEWHERE)
    end

    # 🔴 **本文を伴うメソッドは資格情報の有無を問わず追わない。**
    # ⚠⚠ **本文のキーを列挙する形は、口を足すたびに漏れる**（初版が認証の口 4 つを
    # 素通りさせていた）ので、ヘッダが無くても切る。
    def test_write_requests_never_follow_redirects
      [:post, :put, :delete].each do |method|
        WebMock.reset!
        redirect(method, 302)

        assert_raise(GatewayError, "#{method} が追ってしまった") do
          @http.public_send(method, '/api', {body: {'client_secret' => 'secret'}})
        end
        assert_not_requested(method, ELSEWHERE)
      end
    end

    # ⚠ **資格情報を持たない GET / HEAD は従来どおり追う。** 🔴 ここを切ると、相手が
    # 正規にリダイレクトを返す経路（nodeinfo の探索・Google Apps Script）が壊れる。
    def test_plain_get_still_follows
      redirect(:get, 302)

      assert_equal(200, @http.get('/api').code)
      assert_requested(:get, ELSEWHERE)
    end

    def test_credentialed_get_does_not_follow
      redirect(:get, 302)

      assert_raise(GatewayError) {@http.get('/api', {headers: {'Authorization' => 'Bearer secret'}})}
      assert_not_requested(:get, ELSEWHERE)
    end

    # 🔴 `cookies:` は HTTParty があとからヘッダへ移すので、**ヘッダだけ見ていては
    # 落とせない**。
    def test_cookies_count_as_credentials
      redirect(:get, 302)

      assert_raise(GatewayError) {@http.get('/api', {cookies: {'session' => 'secret'}})}
      assert_not_requested(:get, ELSEWHERE)
    end

    # ⚠ 呼び出し側が明示していたら、そちらを優先する。
    def test_explicit_follow_redirects_wins
      redirect(:get, 302)

      assert_equal(200, @http.get('/api', {
        headers: {'Authorization' => 'Bearer secret'},
        follow_redirects: true,
      }).code)
      assert_requested(:get, ELSEWHERE)
    end

    # ⚠⚠ **3xx を黙って返さない。** 追わないと決めた以上、3xx は「宛先が違う」の合図で、
    # 🔴 応答を検査しない利用側では「送れていないのに成功」と数えられる。
    def test_redirect_without_location_is_not_silent
      stub_request(:get, @url).to_return(status: 300)

      assert_raise(GatewayError) {@http.get('/api')}
    end

    # ⚠ 304 は 3xx に居るがリダイレクトではない。
    def test_not_modified_passes_through
      stub_request(:get, @url).to_return(status: 304)

      assert_equal(304, @http.get('/api').code)
    end

    def test_success_passes_through
      stub_request(:get, @url).to_return(status: 200, body: 'ok')

      assert_equal('ok', @http.get('/api').body)
    end

    # 🔴🔴 **ガードが無ければ 2 段目へ届くことを測る。** ⚠⚠ これが落ちないと、上の
    # assert が「ガードのおかげ」なのか「HTTParty がもともと追わないから」なのかを
    # 区別できない（pooza/ginseng-style のメモにある「緑は守っている証拠にならない」）。
    def test_without_the_guard_the_credential_reaches_the_second_hop
      redirect(:post, 307)
      bare = HTTP.new
      bare.base_uri = ORIGIN
      bare.post('/api', {body: {status: '本文'}, headers: {'Authorization' => 'Bearer secret'}})

      assert_requested(:post, ELSEWHERE, headers: {'Authorization' => 'Bearer secret'})
    end

    # ⚠ **`mkcol` は `Net::HTTP` を直に使うので追従の概念が無い**が、応答は見る。
    # 🔴 `Net::HTTPResponse#code` は **String** を返すので、Integer だけを見ていると
    # ここだけ黙って素通りする。
    def test_mkcol_does_not_return_a_redirect_silently
      stub_request(:mkcol, @url).to_return(status: 301, headers: {'Location' => ELSEWHERE})

      assert_raise(GatewayError) {@http.mkcol('/api')}
    end

    # ⚠ 同じ個体へ何度挟んでも 1 個のまま。
    def test_guard_is_idempotent
      @http.guard_redirects!
      @http.guard_redirects!

      assert_equal(1, @http.singleton_class.ancestors.count(HTTP::RedirectGuard))
    end

    # ⚠ 利用側を模した HTTP と Package。**ガードを知らない**（`Ginseng::HTTP` の子）。
    class ForeignHTTP < Ginseng::HTTP; end

    module ForeignPackage
      include Package

      def http_class
        return ForeignHTTP
      end
    end

    class ForeignSlack < Slack
      include ForeignPackage
    end

    class ForeignLineService < LineService
      include ForeignPackage
    end

    # 🔴🔴 **利用側が `http_class` を差し替えていても届くこと。** ⚠⚠ ガードを
    # `Ginseng::HTTP` のサブクラスとして足す形では、**継承経路に一度も現れない**
    # （fediverse が初版でこれを踏み、3/3 に届いていなかった）。
    def test_guard_reaches_slack_through_a_foreign_http_class
      slack = ForeignSlack.new("#{ORIGIN}/hooks/T000")

      assert_instance_of(ForeignHTTP, slack.instance_variable_get(:@http))
      stub_request(:post, "#{ORIGIN}/hooks/T000")
        .to_return(status: 307, headers: {'Location' => ELSEWHERE})
      stub_request(:post, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {slack.post(text: '本文')}
      assert_not_requested(:post, ELSEWHERE)
    end

    # 🔴 LINE はチャネルアクセストークンを `Authorization` で運ぶ。
    def test_guard_reaches_line_service_through_a_foreign_http_class
      service = ForeignLineService.new(id: 'U000', token: 'secret')
      url = "#{config_class.instance['/line/urls/api']}/v2/bot/message/push"
      stub_request(:post, url).to_return(status: 308, headers: {'Location' => ELSEWHERE})
      stub_request(:post, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {service.say('本文')}
      assert_not_requested(:post, ELSEWHERE)
    end
  end
end
