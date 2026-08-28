# frozen_string_literal: true

module Ginseng
  class LoggerTest < TestCase
    # ⚠ 不正な UTF-8 バイト列。`\xE3\x81` は 3 バイト文字の途中で切れている
    # (#518)。`{s: BROKEN_BYTES}.to_json` は JSON::GeneratorError を上げる。
    BROKEN_BYTES = "\xE3\x81ho"

    # ⚠ 「設定に無い」と「設定に nil が入っている」を区別するための番兵。
    ABSENT = Object.new.freeze

    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @logger = Logger.new
    end

    def test_new
      assert_kind_of(Logger, @logger)
      assert_kind_of(Syslog::Logger, @logger)
    end

    def test_create_message
      assert_kind_of(Hash, @logger.create_message(StandardError.new('a')))
      assert_kind_of(Hash, @logger.create_message(Error.new('a')))
      assert_kind_of(Array, @logger.create_message([1, 2, 3]))
      assert_kind_of(Hash, @logger.create_message(a: 'a', b: 'b'))
      assert_kind_of(String, @logger.create_message('aaaaa'))
      assert_equal('string', @logger.create_message('string'))
      assert_equal({message: 'message'}, @logger.create_message(message: 'message', password: 'hoge'))
      # 行番号をベタ書きすると、このファイルを編集するたびに腐る（実際ずっと
      # 落ちていた）。raise の位置から動的に取る。
      expected_line = __LINE__ + 1
      raise AuthError, 'unauthorized'
    rescue AuthError => e
      assert_equal({
        error: {
          message: 'unauthorized',
          file: 'test/logger_test.rb',
          line: expected_line,
        },
        class: 'Ginseng::LoggerTest',
      }, @logger.create_message(error: e, class: self.class.to_s))
    end

    # ログに渡しただけで呼び出し元の Hash が壊れてはいけない (#478)。
    def test_create_message_does_not_mutate_source
      params = {message: 'message', password: 'hoge', nested: {token: 'x', keep: 'y'}}
      @logger.create_message(params)

      assert_equal('hoge', params[:password])
      assert_equal('x', params.dig(:nested, :token))
    end

    # 文字列キーでもマスクが効くこと。旧実装は symbolize_keys した複製を回しつつ
    # 元の arg を delete していたため、文字列キーでは素の値が出ていた (#478)。
    def test_create_message_masks_string_keys
      assert_equal(
        {message: 'message'},
        @logger.create_message('message' => 'message', 'password' => 'hoge'),
      )
    end

    # 🔴 キーの大文字小文字で判定を変えないこと。`Authorization` は HTTP ヘッダの
    # 綴りそのもので、config には小文字でしか並べられない。完全一致で見ていた
    # ため素通りしていた（`pooza/makoto2` の v0.4.0 リリース前レビューで実測）。
    def test_create_message_masks_mixed_case_keys
      assert_equal(
        {probe: 'mask'},
        @logger.create_message(probe: 'mask', Token: 'SECRET-VALUE'),
      )
      assert_equal(
        {probe: 'mask'},
        @logger.create_message(probe: 'mask', TOKEN: 'SECRET-VALUE'),
      )
      assert_equal(
        {probe: 'mask'},
        @logger.create_message('probe' => 'mask', 'Password' => 'SECRET-VALUE'),
      )
    end

    def test_create_message_masks_nested_values
      assert_equal(
        {a: {b: {keep: 'y'}}},
        @logger.create_message(a: {b: {secret: 'x', keep: 'y'}}),
      )
    end

    # URL の**クエリに埋まった**資格情報が落ちること
    # (pooza/mulukhiya-toot-proxy#4511)。キー名は `url` なので mask_fields では
    # 素通りする。mulukhiya の listener がフルスコープのボットトークンを平文で
    # syslog へ書き続けていた実例がある。
    def test_create_message_masks_url_credentials
      message = @logger.create_message(
        url: 'wss://example.com/api/v1/streaming?access_token=SECRET&stream=user',
      )

      assert_not_include(message[:url], 'SECRET')
      assert_include(message[:url], '[FILTERED]')
      assert_include(message[:url], 'stream=user', '無関係なパラメータは残す')
      assert_include(message[:url], 'wss://example.com/api/v1/streaming', 'ホストとパスは残す')
    end

    # 🔴 **URL の userinfo に埋まったパスワードが落ちること (#589)。**
    #
    # ⚠⚠ **同じ URL のクエリは落ちるのに、隣にあるパスワードは平文で残っていた。**
    # DSN（`postgres://` / `amqp://` / `redis://`）は接続失敗の例外メッセージに
    # 載るので、`@logger.error(error: e)` の経路でそのままログへ出る。
    def test_create_message_masks_url_userinfo
      {
        'postgres://app:S3CRET@db.internal/mydb' => 'app',
        'amqp://guest:S3CRET@mq:5672/' => 'guest',
        # ⚠ **ユーザ名が空の形**（redis の既定）も拾うこと。
        'redis://:S3CRET@redis:6379/0' => nil,
      }.each do |url, user|
        masked = @logger.create_message(url:)[:url]

        assert_not_include(masked, 'S3CRET', url)
        assert_include(masked, '[FILTERED]', url)
        assert_include(masked, user, 'ユーザ名は診断に要るので残す') if user
      end
    end

    # ⚠ userinfo とクエリの両方に当たっても壊れないこと。片方の書き込みが他方を
    # 潰していないかを見る（パスとクエリの組み合わせと同じ形）。
    def test_create_message_masks_url_userinfo_and_query
      message = @logger.create_message(
        url: 'https://user:USERSECRET@example.com/x?token=QUERYSECRET&x=1',
      )

      assert_not_include(message[:url], 'USERSECRET')
      assert_not_include(message[:url], 'QUERYSECRET')
      assert_include(message[:url], 'user:', 'ユーザ名は残す')
      assert_include(message[:url], 'x=1', '無関係なパラメータは残す')
    end

    # 🔴 URL の**パスに埋まった**資格情報が落ちること (#580)。
    #
    # モロヘイヤの webhook は `POST /mulukhiya/webhook/{digest}` で、**パスその
    # ものが資格情報**（digest を知っていれば誰でも投稿できる）。クエリと違い
    # キー名で判定できないため、接頭辞を申告する形で落とす。
    #
    # ⚠ 例外経路ではなく、成功した POST のたびに漏れていた。tomato-shrieker の
    # 本番では `{"method":"POST","url":".../mulukhiya/webhook/<digest>",
    # "status":200}` が平文で syslog に出ていた（2026-08-25 の当日ログで 22 行）。
    def test_create_message_masks_url_path_credentials
      digest = 'fa9c541e163ff35ac49e12dd5ad71dc4e27876a3a5514f46d074e9b6f190652d'
      message = @logger.create_message(
        method: 'POST',
        url: "https://precure.ml/mulukhiya/webhook/#{digest}",
        status: 200,
      )

      assert_not_include(message[:url], digest)
      assert_include(message[:url], '[FILTERED]')
      assert_include(message[:url], 'https://precure.ml/mulukhiya/webhook/', '接頭辞は残す')
    end

    # ⚠ パスとクエリの両方に当たっても壊れないこと。片方の実装が他方の書き込みを
    # 潰していないかを見る。
    def test_create_message_masks_url_path_and_query
      message = @logger.create_message(
        url: 'https://precure.ml/mulukhiya/webhook/PATHSECRET?access_token=QUERYSECRET&x=1',
      )

      assert_not_include(message[:url], 'PATHSECRET')
      assert_not_include(message[:url], 'QUERYSECRET')
      assert_include(message[:url], 'x=1', '無関係なパラメータは残す')
    end

    # ⚠ 伏せるのは接頭辞の次の 1 セグメントだけ。以降のパスは残す。
    def test_create_message_masks_only_one_path_segment
      message = @logger.create_message(url: 'https://precure.ml/mulukhiya/webhook/SECRET/extra')

      assert_not_include(message[:url], 'SECRET')
      assert_include(message[:url], '/extra', '以降のパスは残す')
    end

    # ⚠⚠ **どのルールにも当たらない URL は 1 バイトも変えないこと。** 当たらない
    # ときに parse → to_s で往復すると、正規化で URL が化ける後退が入る。
    def test_create_message_keeps_untouched_url_identical
      [
        'https://matrix.org/blog/feed',
        'https://www.youtube.com/feeds/videos.xml?channel_id=UCabc',
        'https://synapse.b-shock.org/webhook',
        # ⚠ userinfo の判定で巻き込まないこと (#589)。パスワードの無いユーザ名と、
        # `@` を持たないポート指定。
        'https://user@example.com/x',
        'http://example.com:8080/path',
      ].each do |url|
        assert_equal(url, @logger.create_message(url:)[:url])
      end
    end

    # 🔴 **文字列の途中に埋まった URL もマスクされること (#582)。**
    #
    # `URL_PATTERN` は `\A` に錨があるので、**文字列全体が URL** でないと
    # `mask_url` に届かなかった。ところがアプリは例外メッセージへ URL を埋める。
    #
    #   raise GatewayError, "Invalid feed #{id} (#{uri}) #{e.message}"
    #
    # ⚠ webhook の失敗はこの形で出るので、#580 を入れても**呼ばれないので
    # 効かない**状態だった。
    def test_create_message_masks_url_embedded_in_message
      digest = 'fa9c541e163ff35ac49e12dd5ad71dc4e27876a3a5514f46d074e9b6f190652d'
      error = GatewayError.new("Invalid feed x (https://precure.ml/mulukhiya/webhook/#{digest}) Bad response 404")

      message = @logger.create_message(source: 'x', error:)

      assert_not_include(message.to_json, digest)
      assert_include(message.to_json, '[FILTERED]')
      assert_include(message.to_json, 'Bad response 404', '診断に要る情報は残す')
    end

    # ⚠ 1 つの文字列に URL が 2 つあれば両方落ちること。
    def test_create_message_masks_every_embedded_url
      text = 'a https://x.example/?token=AAA and https://y.example/?token=BBB end.'

      masked = @logger.create_message(text)

      assert_not_include(masked, 'AAA')
      assert_not_include(masked, 'BBB')
    end

    # 🔴 **IPv6 リテラルをホストに持つ URL もマスクされること (#601)。**
    #
    # `URL_IN_TEXT_PATTERN` の除外文字クラスに `[` と `]` が入っていたため、
    # `https://` の先へ進めず**一致そのものが起きなかった**。⚠⚠ `mask` は全ての
    # 文字列を `mask_urls_in` に通すので、`token` / `session` が平文で残っていた。
    def test_create_message_masks_url_with_ipv6_literal
      [
        'https://[::1]/?token=SECRET',
        'https://[2001:db8::1]:8080/a?token=SECRET&x=1',
        # ⚠⚠ **userinfo を飛ばしてからホストを見ること（Codex P1）。** `://` の
        # 直後に角括弧を要求すると `https://user:pw@` だけに一致して `[` で切れ、
        # **クエリが mask_url に届かない**。
        'https://user:pw@[::1]/?token=SECRET',
        'https://user@[2001:db8::1]:8080/?token=SECRET',
      ].each do |url|
        masked = @logger.create_message(url:)[:url]

        assert_not_include(masked, 'SECRET', url)
        assert_include(masked, '[FILTERED]', url)
      end
    end

    # ⚠ 文字列の**途中**に埋まった形でも拾うこと（例外メッセージ経路）。
    def test_create_message_masks_embedded_ipv6_url
      masked = @logger.create_message('connect failed https://[::1]/?token=SECRET retry')

      assert_not_include(masked, 'SECRET')
      assert_include(masked, 'https://[::1]/', 'ホストは残す')
      assert_include(masked, 'retry', '後続の文字列は残す')
    end

    # ⚠⚠ **範囲を広げる修正は、広げすぎの回帰を呼ぶ。** 角括弧を許すのは**ホストの
    # 直後だけ**で、Markdown のリンクや `[...]` で括った形はこれまでどおり切れること。
    def test_create_message_keeps_bracketed_url_boundaries
      {
        '[text](https://example.com/?token=SECRET)' =>
          '[text](https://example.com/?token=[FILTERED])',
        'see [https://example.com/?token=SECRET] here' =>
          'see [https://example.com/?token=[FILTERED]] here',
      }.each do |input, expected|
        assert_equal(expected, @logger.create_message(input))
      end
    end

    # 🔴 **不正なバイト列で ArgumentError を上げないこと (#587)。**
    #
    # ⚠⚠ `mask_url` は #518 で塞いであるのに、その手前に置いた `mask_urls_in`
    # が素通しだった。⚠ **利用側は public な `mask_urls_in` を Sentry の
    # `before_send` から直接呼ぶ**（pooza/tomato-shrieker）ので、ここが上げると
    # アプリ側に rescue を書かせることになる。
    #
    # ⚠ **scrub してから落とすこと。** 元の文字列をそのまま返すと URL の
    # 資格情報が平文で残る。
    def test_mask_urls_in_scrubs_broken_bytes
      text = "https://x.example/?token=SECRET #{BROKEN_BYTES}"

      masked = @logger.mask_urls_in(text)

      assert_not_include(masked, 'SECRET', '壊れたバイト列があってもマスクは効くこと')
      assert_include(masked, '[FILTERED]')
      assert_predicate(masked, :valid_encoding?)
    end

    # 🔴 **ASCII 非互換なエンコーディングでも上げないこと (#591)。**
    #
    # ⚠⚠ #587 で足した `scrub` は **UTF-8 の不正バイト列**しか救わない。UTF-16 は
    # その手前の `include?` で `Encoding::CompatibilityError` を上げていた。
    def test_mask_urls_in_handles_ascii_incompatible_encoding
      text = 'https://x.example/?token=SECRET'.encode('UTF-16LE')

      masked = @logger.mask_urls_in(text)

      assert_not_include(masked, 'SECRET')
      assert_include(masked, '[FILTERED]')
    end

    # 🔴 **変換器が無いエンコーディングでも上げないこと (#591)。**
    #
    # ⚠⚠ `UTF-7` / `ISO-2022-JP-2` は dummy encoding で、`encode` が
    # `ConverterNotFoundError` を上げる。⚠ `invalid:` / `undef:` では救えない。
    def test_mask_urls_in_handles_encoding_without_converter
      ['UTF-7', 'ISO-2022-JP-2'].each do |name|
        text = 'https://x.example/?token=SECRET'.dup.force_encoding(Encoding.find(name))

        masked = @logger.mask_urls_in(text)

        assert_not_include(masked, 'SECRET', name)
        assert_include(masked, '[FILTERED]', name)
      end
    end

    # 🔴 **ASCII 互換なものは変換しないこと。** `ASCII-8BIT` に妥当な UTF-8 が
    # 入っている形は実在する（pooza/ginseng-fediverse#265）。`encode` に通すと
    # ⚠⚠ **マスクは効くのに中身が `?` に潰れる**ので、後退として捕まえる。
    def test_mask_urls_in_keeps_valid_utf8_in_binary
      text = 'https://x.example/?token=SECRET あいう'.b

      masked = @logger.mask_urls_in(text)

      assert_not_include(masked, 'SECRET')
      assert_include(masked.dup.force_encoding(Encoding::UTF_8), 'あいう', '中身を潰さないこと')
    end

    # 🔴 **設定へ足したキーが、走っているロガーに効くこと (#592)。**
    #
    # ⚠⚠ **`Config#reload` はテスト専用ではない** — アプリの UI から呼ばれる
    # (`pooza/mulukhiya-toot-proxy` の `UIController`)。単純にメモ化すると、
    # **マスク対象を足して reload したのに古い一覧のまま資格情報を出し続ける**
    # ＝ 直したつもりで直っていない、という一番たちの悪い形になる。
    #
    # ⚠ **3 つとも同じ形でメモ化している**ので、まとめて見る。
    def test_masking_lists_follow_the_configuration
      config = config_class.instance
      # ⚠ `/logger/mask_url_paths` は lib.yaml に無い（既定へ倒れる側）ので、
      # 読むと ConfigError。**在っても無くても戻せる形にする。**
      #
      # ⚠⚠ **元から無かったキーは nil を書き戻すのではなく消すこと（Codex P2）。**
      # `Config` は singleton で、`keys` は値が nil の項も列挙する。nil を代入すると
      # **後続のテストから `/logger/mask_url_paths` が「在る」ように見える**。
      original = ['/logger/mask_fields', '/logger/mask_query_params', '/logger/mask_url_paths']
        .to_h {|key| [key, (config[key] rescue ABSENT)]}
      fields = original['/logger/mask_fields']
      params = original['/logger/mask_query_params']

      assert_equal({probe: 'mask', session: 'SECRET'}, @logger.create_message(probe: 'mask', session: 'SECRET'))
      # ⚠⚠ **メモを先に温めること。** URL を通さないまま config を変えると、
      # `mask_query_params` / `mask_url_paths` は**変更後が初回**になり、
      # メモ化したままでも通ってしまう ＝ 回帰を捕まえられない。
      assert_include(@logger.create_message(url: 'https://example.com/?session=SECRET')[:url], 'SECRET')
      assert_include(@logger.create_message(url: 'https://example.com/hook/SECRET/x')[:url], 'SECRET')

      config['/logger/mask_fields'] = fields + ['session']
      config['/logger/mask_query_params'] = params + ['session']
      config['/logger/mask_url_paths'] = ['/hook/']

      assert_equal({probe: 'mask'}, @logger.create_message(probe: 'mask', session: 'SECRET'))
      assert_not_include(@logger.create_message(url: 'https://example.com/?session=SECRET')[:url], 'SECRET')
      assert_not_include(@logger.create_message(url: 'https://example.com/hook/SECRET/x')[:url], 'SECRET')
    ensure
      original&.each do |key, value|
        if value.equal?(ABSENT)
          config.delete(key)
        else
          config[key] = value
        end
      end
    end

    # 🔴 **mask_fields が mask_query_params より狭かった (#586)。**
    #
    # URL のクエリに `access_token=` が出れば落ちるのに、Hash のキーが
    # `access_token:` だと素通りしていた。⚠ **同じ資格情報が、通り道によって
    # 守られたり守られなかったりする**状態だった。
    def test_create_message_masks_credential_fields
      [
        :access_token, :api_key, :apikey, :authorization, :client_secret,
        :password, :refresh_token, :secret, :token,
        # ⚠ 大文字小文字で判定を変えないこと（#585 の回帰も兼ねる）。
        :Authorization, :Access_Token, :TOKEN
      ].each do |key|
        message = @logger.create_message(probe: 'mask', key => 'S3CRET')

        assert_equal({probe: 'mask'}, message, key.to_s)
      end
    end

    # ⚠⚠ **クエリと同じ広さにはしない (#586)。** `code` / `i` / `key` はクエリの
    # パラメータ名としては資格情報だが、**Hash のキーとしては無関係な値が普通に
    # 入る**。広げすぎると診断に要る値まで消える。
    def test_create_message_keeps_generic_fields
      message = @logger.create_message(code: 404, key: 'name', i: 3)

      assert_equal({code: 404, key: 'name', i: 3}, message)
    end

    # 🔴 **設定は既定を置き換えない。既定と合成する (#586)。**
    #
    # ⚠⚠ **上書きだったころ、広げた既定はどこにも届かなかった** — 利用側 3 本とも
    # 自前で列挙しており、`tomato-shrieker` は列挙しなおしたときに既定の `token` を
    # 落としていた（2026-08-28 の実測）。ここでその形を再現して押さえる。
    def test_masking_lists_merge_with_defaults
      config = config_class.instance
      original = ['/logger/mask_fields', '/logger/mask_query_params', '/logger/mask_url_paths']
        .to_h {|key| [key, (config[key] rescue ABSENT)]}

      # ⚠ `tomato-shrieker` の実際の設定の形（`token` が無い）。
      config['/logger/mask_fields'] = ['password', 'secret', 'auth']
      config['/logger/mask_query_params'] = ['session']
      config['/logger/mask_url_paths'] = ['/hook/']

      assert_equal({probe: 'mask'}, @logger.create_message(probe: 'mask', token: 'SECRET'),
        '既定の token が設定で消えないこと')
      assert_equal({probe: 'mask'}, @logger.create_message(probe: 'mask', auth: 'SECRET'),
        '設定で足したキーは効くこと')
      # ⚠ 設定にも config/lib.yaml にも無いので、**MASK_FIELDS の既定だけ**が根拠。
      assert_equal({probe: 'mask'}, @logger.create_message(probe: 'mask', authorization: 'SECRET'),
        'MASK_FIELDS へ足した既定が効くこと')
      masked = @logger.create_message(url: 'https://example.com/?token=SECRET&session=SECRET')[:url]

      assert_not_include(masked, 'SECRET', '既定と設定の両方が効くこと')
      assert_not_include(
        @logger.create_message(url: 'https://precure.ml/mulukhiya/webhook/SECRET/x')[:url],
        'SECRET',
        '既定の接頭辞が設定で消えないこと',
      )
      assert_not_include(
        @logger.create_message(url: 'https://example.com/hook/SECRET/x')[:url],
        'SECRET',
        '設定で足した接頭辞は効くこと',
      )
    ensure
      original&.each do |key, value|
        if value.equal?(ABSENT)
          config.delete(key)
        else
          config[key] = value
        end
      end
    end

    # 🔴 **入れ子の接頭辞は、より長いほうを採ること（Codex P1・#586）。**
    #
    # ⚠⚠ **合成にしたことで、既定と設定の接頭辞が同時に並ぶようになった。**
    # 並び順で決めると既定の `/mulukhiya/webhook/` が設定の
    # `/mulukhiya/webhook/special/` を隠し、**伏せる 1 セグメントがずれて**
    # 資格情報がそのまま残る。
    def test_masks_the_most_specific_url_path_prefix
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/mulukhiya/webhook/special/']

      masked = @logger.create_message(
        url: 'https://precure.ml/mulukhiya/webhook/special/SECRET',
      )[:url]

      assert_not_include(masked, 'SECRET')
      assert_include(masked, '/mulukhiya/webhook/special/', '秘密の直前で終わる接頭辞を残す')
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # 🔴 **重なる接頭辞は、同じ位置から始まるとは限らない（Codex P1・2 巡目）。**
    #
    # ⚠⚠ **長さでは決められない。** 設定の `/webhook/special/`（17 文字）より
    # 既定の `/mulukhiya/webhook/`（19 文字）のほうが長いので、長さで選ぶと
    # **`special` を伏せて秘密を残す**。**終わりが後ろにあるもの**を採る。
    def test_masks_the_prefix_nearest_to_the_secret
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/webhook/special/']

      masked = @logger.create_message(
        url: 'https://precure.ml/mulukhiya/webhook/special/SECRET',
      )[:url]

      assert_not_include(masked, 'SECRET')
      assert_include(masked, '/mulukhiya/webhook/special/')
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # ⚠ **落とせない接頭辞で諦めないこと。** 秘密に一番近い接頭辞の次が空でも、
    # **当たる接頭辞が他にあれば落とす**。1 つ目で nil を返すと素通りする。
    def test_falls_through_to_the_next_matching_prefix
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/x/']

      masked = @logger.create_message(
        url: 'https://precure.ml/mulukhiya/webhook/SECRET/x/',
      )[:url]

      assert_not_include(masked, 'SECRET')
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # 🔴 **当たった接頭辞は、全部落とすこと（Codex P1・3 巡目）。**
    #
    # ⚠⚠ **合成にしたことで、1 本の URL に既定と設定の接頭辞が同時に当たる。**
    # 1 つ目で `return` すると、**合成前は伏せられていた側が平文で残る** —
    # 「マスクしない方向へは倒さない」という #586 の約束がそこで破れる。
    def test_masks_every_matching_url_path_prefix
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/hook/']

      masked = @logger.create_message(
        url: 'https://precure.ml/hook/SECRET1/mulukhiya/webhook/SECRET2',
      )[:url]

      assert_not_include(masked, 'SECRET1', '設定の接頭辞で伏せていた側を残さない')
      assert_not_include(masked, 'SECRET2')
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # ⚠ **同じ接頭辞が 2 回出ることもある。** 1 つ目だけ伏せると残りが平文で出る。
    def test_masks_every_occurrence_of_a_url_path_prefix
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/hook/']

      masked = @logger.create_message(
        url: 'https://precure.ml/hook/SECRET1/x/hook/SECRET2',
      )[:url]

      assert_not_include(masked, 'SECRET1')
      assert_not_include(masked, 'SECRET2')
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # 🔴 **同じセグメントを 2 回置き換えない（Codex P2）。**
    #
    # ⚠⚠ **終わりが同じ接頭辞は、伏せる範囲も同じになる。** 設定 `/webhook/` と
    # 既定 `/mulukhiya/webhook/` は `/mulukhiya/webhook/ABC/tail` のどちらも
    # `ABC` を指すので、そのまま 2 回置き換えると**元のパスの位置で置き換わって**
    # `[FILTERED]LTERED]` のような壊れた URL になり、秘密が長ければ後ろのパスが
    # 消える。
    def test_masks_a_secret_shared_by_two_prefixes
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/webhook/']

      masked = @logger.create_message(
        url: 'https://precure.ml/mulukhiya/webhook/SECRET/tail',
      )[:url]

      assert_equal('https://precure.ml/mulukhiya/webhook/[FILTERED]/tail', masked)
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # 🔴 **同じ接頭辞どうしで打ち消し合わないこと。**
    #
    # ⚠⚠ 「他の接頭辞と重なるセグメントは伏せない」を**同じ接頭辞にも当てると、
    # 1 つも伏せない URL ができる。** `/hook/hook/SECRET/tail` は `/hook/` が
    # 0 と 5 の 2 か所に当たり、互いの「次の 1 セグメント」を打ち消す。⚠ **秘密が
    # 接頭辞と同じ綴りだったときに素通りする**形（ランダムな URL を通して実測）。
    #
    # ⚠ 同じ接頭辞の出現は同じ具体度なので、優先も抑制もしない ＝ 両方伏せる。
    def test_masks_a_secret_spelled_like_the_prefix
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/hook/']

      masked = @logger.create_message(
        url: 'https://precure.ml/hook/hook/SECRET/tail',
      )[:url]

      assert_equal('https://precure.ml/hook/[FILTERED]/[FILTERED]/tail', masked)
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # 🔴 **落とせない接頭辞に、他の接頭辞を止めさせない（Codex P1・5 巡目）。**
    #
    # 設定 `/webhook/special/` は `/mulukhiya/webhook/special/` に当たるが、
    # **次のセグメントが無い**ので何も伏せない。⚠⚠ それが既定
    # `/mulukhiya/webhook/` の「次の 1 セグメント」を止めていたので、**どちらも
    # 伏せない**形になっていた。抑制してよいのは、**自分が実際に伏せる**接頭辞だけ。
    def test_an_empty_match_does_not_suppress_another_prefix
      config = config_class.instance
      original = config['/logger/mask_url_paths'] rescue ABSENT
      config['/logger/mask_url_paths'] = ['/webhook/special/']

      masked = @logger.create_message(
        url: 'https://precure.ml/mulukhiya/webhook/special/',
      )[:url]

      assert_equal('https://precure.ml/mulukhiya/webhook/[FILTERED]/', masked)
    ensure
      if original.equal?(ABSENT)
        config.delete('/logger/mask_url_paths')
      else
        config['/logger/mask_url_paths'] = original
      end
    end

    # ⚠⚠ **`(` を含む URL の `)` を URL から切り離さないこと。** 一律に末尾の
    # 閉じ括弧を落とすと、正当な URL が壊れる。
    def test_create_message_keeps_parenthesized_url_intact
      text = 'see https://en.wikipedia.org/wiki/Foo_(bar) for detail'

      assert_equal(text, @logger.create_message(text))
    end

    # ⚠ 括弧で囲まれた URL の `)` は URL に食われないこと。
    def test_create_message_does_not_eat_closing_paren
      masked = @logger.create_message('x (https://z.example/?token=SECRET) y')

      assert_not_include(masked, 'SECRET')
      assert_include(masked, ') y', '閉じ括弧の外は残る')
    end

    # ⚠ mask / mask_url / mask_urls_in は Sentry の before_send 等から呼べるよう
    # public (#580 / #582)。内部の判定ヘルパは private のまま。
    # 利用側で同等品を書かせると、マスク対象の列が 2 か所に分かれて必ずズレる。
    def test_mask_is_public
      assert_true(@logger.respond_to?(:mask))
      assert_true(@logger.respond_to?(:mask_url))
      assert_true(@logger.respond_to?(:mask_urls_in))
      assert_false(@logger.respond_to?(:mask_field?), '内部ヘルパは private のまま')
      assert_equal({message: 'a'}, @logger.mask(message: 'a', password: 'SECRET'))
      assert_not_include(@logger.mask_url('https://x.example/a?token=SECRET'), 'SECRET')
    end

    # Misskey のトークンパラメータ `i` も落ちること。汎用名なので URL のクエリに
    # 限って判定している。
    def test_create_message_masks_misskey_token_param
      message = @logger.create_message(url: 'https://example.com/streaming?i=SECRET')

      assert_not_include(message[:url], 'SECRET')

      # Hash のキーとしての :i は URL ではないので落とさない（落とすと無関係な
      # 値まで消える）。
      assert_equal({i: 'plain value'}, @logger.create_message(i: 'plain value'))
    end

    # 資格情報を含まない URL・URL でない文字列は素通しすること。
    def test_create_message_keeps_harmless_strings
      url = 'https://example.com/path?page=2&sort=desc'

      assert_equal(url, @logger.create_message(url:)[:url])
      assert_equal('not a url? really', @logger.create_message(message: 'not a url? really')[:message])
      assert_equal('/api/v1/statuses?token=x', @logger.create_message(message: '/api/v1/statuses?token=x')[:message], 'スキームが無ければ URL 扱いしない')
    end

    # 壊れた URL でも落ちないこと（ログ出力で例外を上げるのが最悪）。
    def test_create_message_survives_malformed_url
      assert_nothing_raised do
        @logger.create_message(url: 'http://[bad?token=x')
      end
    end

    # ⚠⚠ **トップレベルに渡した値もマスクすること (#529)。**
    # 以前は Hash / {error:} / StandardError しか受けず、それ以外は
    # NoMatchingPatternError → rescue で**素通し**していた。
    # ⚠ `logger.info(url)` は最も自然な呼び方なので、経路としては太い。
    def test_create_message_masks_top_level_string
      message = @logger.create_message('https://example.com/?access_token=SECRET')

      assert_not_include(message, 'SECRET')
      assert_include(message, '[FILTERED]')
    end

    def test_create_message_masks_top_level_array
      message = @logger.create_message(['https://example.com/?token=SECRET'])

      assert_not_include(message.first, 'SECRET')
    end

    # ⚠ `error:` に例外以外が入る呼び方がある。型を見ずに backtrace を呼ぶと
    # NoMethodError → rescue → **その行のマスクが丸ごと外れる**（password まで
    # 平文で出ていた）。
    def test_create_message_masks_error_key_without_exception
      message = @logger.create_message(error: 'https://example.com/?token=SECRET', password: 'hoge')

      assert_not_include(message[:error], 'SECRET')
      assert_not_include(message.keys, :password)
    end

    # 例外の message にも URL が埋まることがある。
    def test_create_message_masks_standard_error_message
      message = @logger.create_message(StandardError.new('https://example.com/?token=SECRET'))

      assert_not_include(message[:message], 'SECRET')
    end

    # raise していない例外（backtrace が nil）でも落ちないこと。
    def test_create_message_accepts_unraised_error
      message = @logger.create_message(error: StandardError.new('unraised'), class: 'X')

      assert_equal('unraised', message.dig(:error, :message))
    end

    # ⚠⚠ **マスクを通せなかったら中身を出さない (fail closed)。** 素の src を
    # 返すと、まさにマスクしたかった値が平文で出る（#518 で踏んだ型）。
    def test_create_message_fails_closed
      @logger.define_singleton_method(:mask) {|_arg| raise 'boom'}

      message = @logger.create_message(password: 'hoge', url: 'https://example.com/?token=SECRET')

      assert_true(message[:_mask_error])
      assert_equal('Hash', message[:class])
      assert_equal(['password', 'url'], message[:keys])
      assert_not_include(message.to_json, 'SECRET')
      assert_not_include(message.to_json, 'hoge')
    end

    # 配列やネストの中の URL にも効くこと。
    def test_create_message_masks_url_in_nested_values
      message = @logger.create_message(a: ['https://example.com/?token=SECRET'])

      assert_not_include(message.dig(:a, 0), 'SECRET')
    end

    # ⚠ **info / error だけを見ていると穴に気づけない** (#499)。severity を
    # 変えただけで create_message を素通りし、JSON 化もマスキングもされない
    # 状態に戻る。実際に mulukhiya が warn で URL を出していた。
    data('debug', :debug)
    data('warn', :warn)
    data('fatal', :fatal)
    data('info', :info)
    data('error', :error)
    def test_severity_goes_through_create_message(severity)
      captured = capture_syslog {@logger.send(severity, url: 'https://example.com/?token=SECRET', password: 'hoge')}
      # JSON であること（Hash#to_s へ倒れていない）。
      body = JSON.parse(captured.first)

      assert_equal(1, captured.size)
      assert_not_include(body['url'], 'SECRET')
      assert_not_include(body.keys, 'password')
    end

    # ⚠⚠ **raise していない例外を error に渡すと、バックトレース展開が nil を
    # each して NoMethodError を上げ、呼び出し側が落ちていた**（このコミット
    # までの main で arg 形式が再現する。Codex P2）。⚠ `create_message` 側は
    # #518 で塞いである（`test_create_message_accepts_unraised_error`）のに、
    # 展開のほうが素通しだった。**1 行目は出ているので症状が原因から遠い。**
    data('arg', false)
    data('block', true)
    def test_error_accepts_unraised_error(block_form)
      error = StandardError.new('unraised')
      captured = capture_syslog do
        block_form ? @logger.error {error} : @logger.error(error)
      end
      body = JSON.parse(captured.first)

      assert_equal(1, captured.size, 'バックトレースの行が出ないこと')
      assert_equal('unraised', body['message'])
    end

    # ⚠ ブロック形式は Syslog::Logger の既存インタフェース。必須引数にすると
    # `logger.warn {expensive}` が ArgumentError で落ちる (#499 の Codex P2)。
    data('debug', :debug)
    data('info', :info)
    data('warn', :warn)
    data('fatal', :fatal)
    data('error', :error)
    def test_severity_accepts_block_form(severity)
      captured = capture_syslog {@logger.send(severity) {{url: 'https://example.com/?token=SECRET'}}}
      body = JSON.parse(captured.first)

      assert_equal(1, captured.size)
      assert_not_include(body['url'], 'SECRET')
    end

    # severity が無効ならブロックを評価しない（遅延の意味が失われる）。
    data('debug', :debug)
    data('info', :info)
    data('warn', :warn)
    data('fatal', :fatal)
    data('error', :error)
    def test_severity_skips_block_when_disabled(severity)
      called = false
      @logger.level = ::Logger::Severity::UNKNOWN
      captured = capture_syslog do
        @logger.send(severity) do
          called = true
          'message'
        end
      end

      assert_empty(captured)
      assert_false(called)
    ensure
      @logger.level = ::Logger::Severity::DEBUG
    end

    # ⚠⚠ **不正なバイト列でログが 1 行丸ごと消えてはいけない (#518)。**
    # `create_message` には rescue があるのに `to_json` はその外にあり、
    # JSON::GeneratorError がそのまま呼び出し側へ抜けていた。⚠ ログを出そうと
    # した側が落ちるので、**症状が原因から遠いところに出る**（mulukhiya では
    # リクエストログが残らないうえ、本来と違う 401 でクライアントへ返っていた）。
    data('値', {s: BROKEN_BYTES})
    data('キー', {BROKEN_BYTES => 'value'})
    data('文字列', BROKEN_BYTES)
    data('配列', [BROKEN_BYTES])
    data('binary', {s: BROKEN_BYTES.b})
    def test_info_survives_broken_bytes(message)
      captured = capture_syslog {@logger.info(message)}
      body = JSON.parse(captured.first)

      assert_equal(1, captured.size, '1 行出ること')
      assert_true(body['_encoding_error'], '直したことを隠さない')
    end

    # ⚠ **壊れていない部分は残すこと。** 行ごと捨てるのと変わらなくなる。
    def test_info_keeps_readable_part_of_broken_bytes
      captured = capture_syslog {@logger.info(url: 'https://example.com/', s: BROKEN_BYTES)}
      body = JSON.parse(captured.first)

      assert_equal('https://example.com/', body['url'])
      assert_include(body['s'], 'ho')
    end

    # ⚠⚠ **scrub してもマスクは効いたままであること。** ここが抜けると、
    # 「壊れたバイト列を送れば資格情報が平文で出る」という穴になる。
    def test_info_masks_even_when_scrubbed
      captured = capture_syslog do
        @logger.info(password: 'hoge', url: "https://example.com/?token=SECRET&s=#{BROKEN_BYTES}")
      end
      body = JSON.parse(captured.first)

      assert_true(body['_encoding_error'])
      assert_not_include(body.keys, 'password')
      assert_not_include(body['url'], 'SECRET')
    end

    # 壊れていないメッセージに印を付けないこと（付くと意味を失う）。
    def test_info_does_not_mark_healthy_message
      captured = capture_syslog {@logger.info(message: 'あいうえお')}
      body = JSON.parse(captured.first)

      assert_equal('あいうえお', body['message'])
      assert_not_include(body.keys, '_encoding_error')
    end

    # error はバックトレースを個別に出すので、そちらでも落ちないこと。
    def test_error_survives_broken_bytes
      error = StandardError.new("broken #{BROKEN_BYTES}")
      error.set_backtrace(["#{BROKEN_BYTES}:1:in 'x'"])

      captured = capture_syslog {@logger.error(error)}

      assert_operator(captured.size, :>=, 2, '本体とバックトレースが出ること')
      assert_true(JSON.parse(captured.first)['_encoding_error'])
    end

    private

    # Syslog::Logger の各 severity は add へ集約されるので、そこで捕まえる。
    def capture_syslog
      captured = []
      @logger.define_singleton_method(:add) do |_severity, message = nil, _progname = nil|
        captured.push(message)
        true
      end
      yield
      return captured
    end
  end

  # ⚠⚠ **プラットフォームで分岐する差分を、片方でしか走らないテストで守らない
  # (#602 / #604)。** LoggerTest は `disable?` で `win?` を見てクラスごと omit し、
  # **CI は `ubuntu-latest` しか回さない**ので、Windows のスタブは元から 1 行も
  # 検査されていなかった。⚠⚠ **`disable?` を足すだけでは足りない** — Linux では
  # そもそも Windows のクラスが定義されず、テストは緑のまま通り抜ける。
  #
  # ⚠ `WindowsLogger` は `win?` の外で定義してあるので、**ここではどの環境でも
  # 実物を直に叩ける**（分岐に依存しない）。
  class LoggerPlatformParityTest < TestCase
    # `mask` / `mask_url` / `mask_urls_in` は **public として配っている** API
    # (masking.rb の冒頭。Sentry の before_send から呼ばれる)。
    MASKING_METHODS = [:mask, :mask_url, :mask_urls_in].freeze
    SEVERITIES = [:debug, :info, :warn, :error, :fatal].freeze

    def test_masking_is_public_on_windows
      assert_include(WindowsLogger.ancestors, Masking)

      MASKING_METHODS.each do |name|
        assert_true(WindowsLogger.public_method_defined?(name), "WindowsLogger##{name} が public でない")
      end
    end

    def test_masking_is_public_on_the_current_platform
      assert_include(Logger.ancestors, Masking)

      MASKING_METHODS.each do |name|
        assert_true(Logger.public_method_defined?(name), "Logger##{name} が public でない")
      end
    end

    # ⚠ **include しただけでは足りない。** Masking は include する側が `@config`
    # を持つことを要求しているので、実際にマスクが効くところまで見る。
    def test_windows_logger_masks
      logger = WindowsLogger.new('probe')

      assert_equal({probe: 'mask'}, logger.mask(probe: 'mask', password: 'SECRET-VALUE'))
      assert_not_include(logger.mask_url('https://example.com/?access_token=SECRET-VALUE'), 'SECRET-VALUE')
    end

    # ⚠ スタブに initialize が無いと、`Logger.new(name)` が Windows でだけ
    # ArgumentError になっていた。
    def test_accepts_optional_name
      assert_nothing_raised {WindowsLogger.new}
      assert_nothing_raised {WindowsLogger.new('probe')}
      assert_nothing_raised {Logger.new}
      assert_nothing_raised {Logger.new('probe')}
    end

    # ⚠ severity はブロック形式を殺さない（実装側と同じ）。
    def test_severities_accept_block_form
      [WindowsLogger.new, Logger.new].each do |logger|
        SEVERITIES.each do |severity|
          assert_nothing_raised {logger.public_send(severity) {'probe'}}
        end
      end
    end

    # ⚠⚠ **差し替えが配線されていること。** 上の 2 本は「両方のクラスが正しい」
    # ことしか見ないので、`Logger` がどちらを指すかはここで押さえる。
    def test_windows_branch_is_wired
      return assert_same(WindowsLogger, Logger) if Environment.win?

      assert_operator(Logger, :<, Syslog::Logger)
    end
  end
end
