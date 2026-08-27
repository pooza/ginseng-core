# frozen_string_literal: true

module Ginseng
  class LoggerTest < TestCase
    # ⚠ 不正な UTF-8 バイト列。`\xE3\x81` は 3 バイト文字の途中で切れている
    # (#518)。`{s: BROKEN_BYTES}.to_json` は JSON::GeneratorError を上げる。
    BROKEN_BYTES = "\xE3\x81ho"

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

    # 🔴 **ASCII 互換なものは変換しないこと。** `ASCII-8BIT` に妥当な UTF-8 が
    # 入っている形は実在する（pooza/ginseng-fediverse#265）。`encode` に通すと
    # ⚠⚠ **マスクは効くのに中身が `?` に潰れる**ので、後退として捕まえる。
    def test_mask_urls_in_keeps_valid_utf8_in_binary
      text = 'https://x.example/?token=SECRET あいう'.b

      masked = @logger.mask_urls_in(text)

      assert_not_include(masked, 'SECRET')
      assert_include(masked.dup.force_encoding(Encoding::UTF_8), 'あいう', '中身を潰さないこと')
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
end
