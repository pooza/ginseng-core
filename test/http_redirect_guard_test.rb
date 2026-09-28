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
    MASK_QUERY_KEY = '/logger/mask_query_params'

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

    # ⚠ `mask_query_params` をシンボルで返す logger。正規化の有無を測るためだけの double。
    class SymbolMaskLogger < Ginseng::Logger
      def mask_query_params
        return [:access_token, :token]
      end
    end

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
      # 🔴🔴 **`Config#reload` は書いたキーを消さない**（`load` は `@raw` を見て
      # merge するだけ）。⚠⚠ シングルトンなので、消さないと**他のテストの前提を
      # 壊す** — 実測で `/slack/hooks` を書いたら `SlackTest#disable?` が false に
      # なり、本物の Slack へ送ろうとして 2 件 error になった。
      config_class.instance.delete(MASK_QUERY_KEY)
    end

    def image
      return File.join(Environment.dir, 'images/pooza.png')
    end

    def redirect(method, status, location = ELSEWHERE)
      stub_request(method, @url).to_return(status:, headers: {'Location' => location})
      return stub_request(method, location).to_return(status: 200, body: '2 段目')
    end

    def allow_hosts(*hosts)
      return ->(host) {hosts.include?(host)}
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

    # 🔴🔴 **`host_validator` を渡した経路でも効くこと (#653 Codex P1)。**
    # ⚠⚠ あの経路は `follow_redirects: false` を HTTParty へ渡したうえで**自前で
    # ホップを追う**ので、ガードが同じキーを立てただけでは追従が止まらなかった。
    # 🔴 307 / 308 は body を持ち越すので、**validator が通る別ホストへ本文の
    # 資格情報がそのまま渡る**。
    def test_credentialed_post_with_host_validator_never_reaches_the_second_hop
      redirect(:post, 307)

      assert_raise(GatewayError) do
        @http.post('/api', {
          body: {'client_secret' => 'secret'},
          host_validator: allow_hosts('example.com', 'elsewhere.example.com'),
        })
      end
      assert_not_requested(:post, ELSEWHERE)
    end

    # 🔴🔴 **ガードが無ければ、validator を通る別ホストへ本文が届くことを測る。**
    def test_without_the_guard_the_validator_path_forwards_the_body
      redirect(:post, 307)
      bare = HTTP.new
      bare.base_uri = ORIGIN
      bare.post('/api', {
        body: {'client_secret' => 'secret'},
        host_validator: allow_hosts('example.com', 'elsewhere.example.com'),
      })

      assert_requested(:post, ELSEWHERE, body: {'client_secret' => 'secret'})
    end

    # ⚠ validator を渡した GET は、資格情報が無ければ従来どおり追う。
    def test_plain_get_with_host_validator_still_follows
      redirect(:get, 302)

      assert_equal(200, @http.get('/api', {
        host_validator: allow_hosts('example.com', 'elsewhere.example.com'),
      }).code)
      assert_requested(:get, ELSEWHERE)
    end

    # 🔴🔴 **クエリに載った資格情報も資格情報 (#653 Codex P1)。**
    # ⚠⚠ ヘッダにも `CREDENTIAL_OPTIONS` にも現れないので、見落とすと**追従が
    # 有効なまま次のホストへ渡る**。
    def test_query_credentials_are_detected
      stub_request(:get, @url).with(query: {'access_token' => 'secret'})
        .to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {@http.get('/api', {query: {access_token: 'secret'}})}
      assert_not_requested(:get, ELSEWHERE)
    end

    # ⚠ `options[:query]` ではなく **URI に直に書いた**場合も拾う。
    def test_query_credentials_in_the_uri_are_detected
      stub_request(:get, @url).with(query: {'api_key' => 'secret'})
        .to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {@http.get('/api?api_key=secret')}
      assert_not_requested(:get, ELSEWHERE)
    end

    # 🔴🔴 **突き合わせる前に復号する (#653 Codex P1・2 巡目)。** `access%5Ftoken` は
    # サーバー側では `access_token` として読まれるので、生の字面で比べると一致せず
    # **「資格情報なし」に落ちて黙って追従する**。
    def test_percent_encoded_query_credentials_are_detected
      stub_request(:get, @url).with(query: {'access_token' => 'secret'})
        .to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {@http.get('/api', {query: 'access%5Ftoken=secret'})}
      assert_not_requested(:get, ELSEWHERE)
    end

    # ⚠⚠ **壊れたエスケープは安全側（資格情報あり）へ倒す。**
    # 🔴 **初版のテストは空振りしていた** — `query: '%zz=1'` は `Addressable` が
    # 要求を出す前に弾くので（`GatewayError: invalid percent escape`・要求 0 件）、
    # ガードを外しても緑だった。⚠ 公開の口からは踏めないので、判定そのものを見る。
    def test_malformed_escape_is_classified_as_a_credential
      assert_nil(@http.send(:query_keys, '%zz=1'))
      assert_true(@http.send(:credential_query?, {query: '%zz=1'}))
    end

    # ⚠ **資格情報でないクエリは従来どおり追う。** 🔴 一律に切ると、相手が正規に
    # リダイレクトを返す GET（検索・ページング）が壊れる。
    def test_benign_query_still_follows
      stub_request(:get, @url).with(query: {'page' => '2'})
        .to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      assert_equal(200, @http.get('/api', {query: {page: 2}}).code)
      assert_requested(:get, ELSEWHERE)
    end

    # 🔴🔴 **慣習的な名前の資格情報ヘッダも止める (#653・リリース前レビュー観点①)。**
    # ⚠⚠ **こちらは実際に 2 段目へ届く** — 上流の `send_authorization_header?` が
    # 落とすのは `basic_auth` から作った `Authorization` だけで、素の headers は
    # 別ホストへもそのまま撃ち直される（実測）。
    def test_custom_credential_headers_are_detected
      ['X-Api-Key', 'X-Auth-Token', 'Private-Token', 'Authentication', 'X-Amz-Security-Token'].each do |name|
        WebMock.reset!
        redirect(:get, 302)

        assert_raise(GatewayError, "#{name} が素通りした") do
          @http.get('/api', {headers: {name => 'secret'}})
        end
        assert_not_requested(:get, ELSEWHERE)
      end
    end

    # ⚠ **資格情報でない custom ヘッダは従来どおり追う。** 🔴 名前の形で見る以上、
    # 巻き込みすぎていないことを固定する（利用側の実例は `X-Mulukhiya` / `X-Trace`）。
    def test_benign_custom_headers_still_follow
      redirect(:get, 302)

      assert_equal(200, @http.get('/api', {headers: {'X-Trace' => 'abc', 'X-Mulukhiya' => '1'}}).code)
      assert_requested(:get, ELSEWHERE)
    end

    # 🔴🔴 **userinfo は options に現れない (#653・リリース前レビュー観点①)。**
    # ⚠ 実測で、同じホストの `http://` へ 302 を返されると **Basic が平文のまま
    # 2 段目へ再送された**。
    def test_userinfo_is_detected
      # ⚠ HTTParty は要求を出す前に userinfo を `Authorization: Basic` へ移すので、
      # stub は**移したあとの形**で書く（実測で確認）。
      stub_request(:get, 'https://example.com/api').with(basic_auth: ['user', 'pass'])
        .to_return(status: 302, headers: {'Location' => 'http://example.com/moved'})
      stub_request(:get, 'http://example.com/moved').to_return(status: 200)

      assert_raise(GatewayError) {HTTP.new.guard_redirects!.get('https://user:pass@example.com/api')}
      assert_not_requested(:get, 'http://example.com/moved')
    end

    # 🔴🔴 **本文を載せた GET も追わない (#653 Codex P1・4 巡目)。**
    # ⚠⚠ `host_validator` を渡した経路は 307 / 308 で `keep_body` を立て、**GET は
    # SAFE_METHODS なのでメソッドも変えない**ので、`redirect_options` が本文を
    # オリジンをまたいで持ち越す。
    def test_get_with_a_body_does_not_follow
      redirect(:get, 307)

      assert_raise(GatewayError) do
        @http.get('/api', {
          body: {'client_secret' => 'secret'},
          host_validator: allow_hosts('example.com', 'elsewhere.example.com'),
        })
      end
      assert_not_requested(:get, ELSEWHERE)
    end

    # 🔴 **ガードが無ければ 2 段目へ本文が届くことを測る。**
    def test_without_the_guard_the_get_body_reaches_the_second_hop
      redirect(:get, 307)
      bare = HTTP.new
      bare.base_uri = ORIGIN
      bare.get('/api', {
        body: {'client_secret' => 'secret'},
        host_validator: allow_hosts('example.com', 'elsewhere.example.com'),
      })

      assert_requested(:get, ELSEWHERE, body: 'client_secret=secret')
    end

    # 🔴🔴 **スキーム相対の userinfo も見る (#653 Codex P1・3 巡目)。**
    # ⚠⚠ `create_uri` は `base_uri` から scheme / host / port を補うだけで
    # **userinfo を落とさない**ので、`//user:pass@host/api` はそのまま Basic になる。
    # 🔴 字面で `scheme://...@` を探していた間、ここが素通りしていた。
    def test_scheme_relative_userinfo_is_detected
      stub_request(:get, @url).with(basic_auth: ['user', 'pass'])
        .to_return(status: 302, headers: {'Location' => 'http://example.com/moved'})
      stub_request(:get, 'http://example.com/moved').to_return(status: 200)

      assert_raise(GatewayError) {@http.get('//user:pass@example.com/api')}
      assert_not_requested(:get, 'http://example.com/moved')
    end

    # ⚠ `default_params` も HTTParty が正式に受けるクエリ。
    def test_default_params_credentials_are_detected
      stub_request(:get, @url).with(query: {'access_token' => 'secret'})
        .to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {@http.get('/api', {default_params: {access_token: 'secret'}})}
      assert_not_requested(:get, ELSEWHERE)
    end

    # ⚠ Array 形の query も見る。🔴 **HTTParty は先頭の Array を潰す** ので
    # `[['api_key', 'secret']]` は `?api_key&secret` になる（実測）＝ 値を伴わない
    # パラメータ名の列。⚠⚠ そのため**要求としては資格情報を運べない**が、判定を
    # Hash / String だけにしておくと中途半端なので、ここも見る。
    def test_array_query_is_classified
      assert_equal(['api_key'], @http.send(:query_keys, [['api_key', 'secret']]))
      assert_true(@http.send(:credential_query?, {query: [['api_key', 'secret']]}))
      assert_true(@http.send(:credential_query?, {query: ['access_token', 'x']}))
    end

    # 🔴🔴 **`follow_redirects: nil` は「追う」ではない (#653・リリース前レビュー観点①)。**
    # ⚠⚠ `guarded_options` は `key?` で「呼び出し側の明示」と読むので素通りする。
    # 🔴 validator 経路だけ `!= false` で見ていると、**Codex P1 の穴がそのまま再開する**
    # （`follow_redirects: config['...']` でキーが在って値が `nil` の形）。
    def test_nil_follow_redirects_does_not_follow_in_the_validator_path
      redirect(:post, 307)

      assert_raise(GatewayError) do
        @http.post('/api', {
          body: {'client_secret' => 'secret'},
          follow_redirects: nil,
          host_validator: allow_hosts('example.com', 'elsewhere.example.com'),
        })
      end
      assert_not_requested(:post, ELSEWHERE)
    end

    # ⚠ **`mkcol` は `Net::HTTP` を直に使うので追従の概念が無い**が、応答は見る。
    # 🔴 `Net::HTTPResponse#code` は **String** を返すので、Integer だけを見ていると
    # ここだけ黙って素通りする。
    def test_mkcol_does_not_return_a_redirect_silently
      stub_request(:mkcol, @url).to_return(status: 301, headers: {'Location' => ELSEWHERE})

      assert_raise(GatewayError) {@http.mkcol('/api')}
    end

    # 🔴🔴 **`upload` の継ぎ目を測る (#653・リリース前レビュー観点②)。**
    # ⚠⚠ **この 2 つの override を消すと、483 tests が全部緑のまま**、添付の本文と
    # `Authorization` が別ホストの 2 段目へ届く（実測で確認した）。⚠ `upload` に
    # `follow_redirects` を混ぜても黙って捨てられるので、効いているのは
    # `upload_options` 側 — コメントが「いちばん間違えやすい継ぎ目」と書いている場所。
    def test_credentialed_upload_never_reaches_the_second_hop
      stub_request(:post, @url).to_return(status: 307, headers: {'Location' => ELSEWHERE})
      stub_request(:post, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) do
        @http.upload('/api', image, {headers: {'Authorization' => 'Bearer secret'}})
      end
      assert_not_requested(:post, ELSEWHERE)
    end

    # 🔴 **ガードが無ければ添付ごと 2 段目へ届くことを測る。**
    def test_without_the_guard_the_upload_reaches_the_second_hop
      stub_request(:post, @url).to_return(status: 307, headers: {'Location' => ELSEWHERE})
      stub_request(:post, ELSEWHERE).to_return(status: 200)
      bare = HTTP.new
      bare.base_uri = ORIGIN
      bare.upload('/api', image, {headers: {'Authorization' => 'Bearer secret'}})

      assert_requested(:post, ELSEWHERE, headers: {'Authorization' => 'Bearer secret'})
    end

    # 🔴🔴 **利用側が `/logger/mask_query_params` に足した名前でも効くこと
    # (#653・リリース前レビュー観点②)。** ⚠⚠ これが無いと、`Masking` と一覧を共有した
    # という主張そのものが未測定になる（`public :mask_query_params` の 1 行を消しても
    # 定数へフォールバックするので、既定の名前しか使わないテストでは差が出ない）。
    def test_consumer_configured_query_names_are_honored
      config_class.instance[MASK_QUERY_KEY] = ['my_private_ticket']
      stub_request(:get, @url).with(query: {'my_private_ticket' => 'secret'})
        .to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {HTTP.new.guard_redirects!.get("#{@url}?my_private_ticket=secret")}
      assert_not_requested(:get, ELSEWHERE)
    end

    # ⚠ **シンボルで返す logger を差されても効くこと。** 🔴 正規化を片方の枝でしか
    # していなかった間は、クエリの検出が丸ごと無効になっていた。
    def test_symbol_query_names_are_normalized
      logger = SymbolMaskLogger.new
      http = HTTP.new.guard_redirects!
      http.instance_variable_set(:@logger, logger)
      http.base_uri = ORIGIN
      stub_request(:get, @url).with(query: {'access_token' => 'secret'})
        .to_return(status: 302, headers: {'Location' => ELSEWHERE})
      stub_request(:get, ELSEWHERE).to_return(status: 200)

      assert_raise(GatewayError) {http.get('/api', {query: {access_token: 'secret'}})}
      assert_not_requested(:get, ELSEWHERE)
    end

    # ⚠ 同じインスタンスへ何度挟んでも 1 個のまま。
    def test_guard_is_idempotent
      @http.guard_redirects!
      @http.guard_redirects!

      assert_equal(1, @http.singleton_class.ancestors.count(HTTP::RedirectGuard))
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
