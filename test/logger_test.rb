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

    # 🔴 **署名付き URL の署名が落ちること (#690)。** ⚠ 署名付き URL に限らない名前
    # （`hm` / `jwt` / `authorization`。#693）も同じ表で見る。⚠ 既定の一覧が署名系の名前を
    # 1 つも持たず、第三者が渡す URL の署名が `url:` にも文中にも平文で残っていた。
    #
    # ⚠⚠ **設定ではなく既定（定数）で落ちること。** 利用側の設定は既定に足す形なので、
    # 🔴 この gem の `config/lib.yaml` だけに足しても利用側には届かない。
    SIGNED_URLS = {
      'x-amz-signature' => 'https://b.s3.amazonaws.com/a.png?X-Amz-Credential=AKIDEXAMPLE&X-Amz-Signature=SECRET',
      'x-amz-security-token' => 'https://b.s3.amazonaws.com/a.png?X-Amz-Credential=AKIDEXAMPLE&X-Amz-Security-Token=SECRET',
      'x-goog-signature' => 'https://storage.googleapis.com/b/a.png?X-Goog-Credential=AKIDEXAMPLE&X-Goog-Signature=SECRET',
      'sig' => 'https://a.blob.core.windows.net/c/a.png?sv=AKIDEXAMPLE&sig=SECRET',
      'signature' => 'https://d.cloudfront.net/a.png?Key-Pair-Id=AKIDEXAMPLE&Signature=SECRET',
      # ⚠ 署名付き URL に限らない名前（#693）。
      'hm' => 'https://cdn.discordapp.com/attachments/1/2/a.png?ex=AKIDEXAMPLE&hm=SECRET',
      'jwt' => 'https://private-user-images.githubusercontent.com/a.png?v=AKIDEXAMPLE&jwt=SECRET',
      'authorization' => 'https://f000.backblazeb2.com/file/b/a.png?b=AKIDEXAMPLE&Authorization=SECRET',
      # ⚠ #701 で足した名前。Alibaba OSS / Tencent COS / Akamai / ほか。
      'x-oss-signature' => 'https://b.oss-cn-hangzhou.aliyuncs.com/a.png?OSSAccessKeyId=AKIDEXAMPLE&x-oss-signature=SECRET',
      'x-oss-security-token' => 'https://b.oss-cn-hangzhou.aliyuncs.com/a.png?OSSAccessKeyId=AKIDEXAMPLE&x-oss-security-token=SECRET',
      'security-token' => 'https://b.oss-cn-hangzhou.aliyuncs.com/a.png?OSSAccessKeyId=AKIDEXAMPLE&security-token=SECRET',
      'q-signature' => 'https://b.cos.ap-tokyo.myqcloud.com/a.png?q-ak=AKIDEXAMPLE&q-signature=SECRET',
      'x-cos-security-token' => 'https://b.cos.ap-tokyo.myqcloud.com/a.png?q-ak=AKIDEXAMPLE&x-cos-security-token=SECRET',
      'hdnts' => 'https://a.akamaized.net/a.m3u8?id=AKIDEXAMPLE&hdnts=SECRET',
      '__token__' => 'https://a.akamaized.net/a.m3u8?id=AKIDEXAMPLE&__token__=SECRET',
      'api-key' => 'https://api.example.com/v1?client=AKIDEXAMPLE&api-key=SECRET',
      'x-api-key' => 'https://api.example.com/v1?client=AKIDEXAMPLE&x-api-key=SECRET',
      'id_token' => 'https://app.example.com/cb?state=AKIDEXAMPLE&id_token=SECRET',
      'auth' => 'https://p.firebaseio.com/a.json?print=AKIDEXAMPLE&auth=SECRET',
      'hmac' => 'https://shop.example.com/cb?shop=AKIDEXAMPLE&hmac=SECRET',
    }.freeze

    # 🔴🔴 **走査が途中で切れたり、パースに失敗したりすると、後ろのクエリが丸ごと素通りする (#700)。**
    # ⚠ `url:` 欄（まるごと URL）と文中の両方で見る。⚠⚠ 部分一致で見ること — `sig=SEC|RET` は
    # `SECRET` を含まなくても `RET` が漏れている。
    SCAN_BREAKING_URLS = [
      'https://b.s3.amazonaws.com/a?X-Amz-Date=1&amp;X-Amz-Signature=SECRET',
      'https://h.example/a?x=1\\&sig=SECRET',
      'https://h.example/a?x=^&sig=SECRET',
      'https://h.example/a?x={1}&sig=SECRET',
      'https://h.example/a?sig=SEC|RET',
      'https://h.example/a?sig=SEC{RET',
      'https://h.example/a?sig=SEC[RET',
      'https://h.example/a?sig[]=SECRET',
      'https://h.example/a?sig[0]=SECRET',
      'https://h.example/a?a=1;sig=SECRET',
      'https://h.example/a#sig=SECRET',
      'https://h.example/a#access_token=SECRET&token_type=bearer',
      'https://h.example/cb?redirect=https://x.example/?token=SECRET',
      # 🔴 `;` / `?` は値の中にも現れる。次に `名前=` が続かなければ値の一部（Codex P1）。
      'https://h.example/a?token=SEC;RET',
      'https://h.example/a?token=SEC?RET&x=1',
      # ⚠ Addressable が読めない形（閉じていない IPv6 の `[`）。
      'https://[::1/a?sig=SECRET',
    ].freeze

    # ⚠ 文中では空白・引用符・`<>` が URL の終わりの目印なので、`url:` 欄でだけ見る形。
    WHOLE_URL_ONLY = [
      'https://h.example/a?x=<1>&sig=SECRET',
      'https://h.example/a?x="1"&sig=SECRET',
      'https://h.example/a?x=a b&sig=SECRET',
      'https://b.s3.amazonaws.com/a.png?response-content-disposition=attachment; filename="a.png"&X-Amz-Signature=SECRET',
    ].freeze

    def test_create_message_masks_scan_breaking_urls
      SCAN_BREAKING_URLS.each do |url|
        field = @logger.create_message(url:)[:url]
        embedded = @logger.create_message(message: "failed (#{url}). retry")[:message]

        [field, embedded].each do |masked|
          # ⚠ `RET` も見る（`sig=SEC|RET` は途中から漏れていた）。
          assert_not_include(masked, 'RET', url)
          assert_include(masked, '[FILTERED]', url)
        end
        assert_true(embedded.end_with?('). retry'), "後ろの文を食わないこと: #{embedded}")
      end
      WHOLE_URL_ONLY.each do |url|
        assert_not_include(@logger.create_message(url:)[:url], 'SECRET', url)
      end
    end

    # ⚠⚠ **伏せないところは 1 バイトも変えない (#700)。** パースして組み直していたころは、
    # 伏せるたびに隣のパラメータが正規化されていた（`a+b` → `a%20b`、`(bar)?…)` の `)` →
    # `%29`）。
    def test_create_message_keeps_the_rest_of_the_url
      {
        'https://h.example/s?q=a+b&i=SECRET' => 'https://h.example/s?q=a+b&i=[FILTERED]',
        'https://h.example/s?access%5Ftoken=SECRET&x=%E3%81%82' => 'https://h.example/s?access%5Ftoken=[FILTERED]&x=%E3%81%82',
        'https://h.example/s?token=' => 'https://h.example/s?token=[FILTERED]',
        'https://h.example/s?flag&token=SECRET' => 'https://h.example/s?flag&token=[FILTERED]',
      }.each do |url, expected|
        assert_equal(expected, @logger.create_message(url:)[:url], url)
      end
      assert_equal(
        'error (https://h.example/wiki/Foo_(bar)?a=1&token=[FILTERED]&b=2). retry',
        @logger.create_message(message: 'error (https://h.example/wiki/Foo_(bar)?a=1&token=SECRET&b=2). retry')[:message],
      )
      # ⚠ URL で始まって文が続く文字列で、パスのマスクが後ろの文を食わないこと（Codex P2）。
      assert_equal(
        'https://h.example/mulukhiya/webhook/[FILTERED] failed afterward',
        @logger.create_message(message: 'https://h.example/mulukhiya/webhook/SECRET failed afterward')[:message],
      )
      # ⚠ Markdown の括りは従来どおり食わない。
      assert_equal(
        '[https://h.example/?token=[FILTERED]](https://h.example/?token=[FILTERED])',
        @logger.create_message(message: '[https://h.example/?token=SECRET](https://h.example/?token=SECRET)')[:message],
      )
    end

    # 🔴🔴 **長い英数字の連続で、走査が入力長の 2 乗にならないこと（3.0.0 リリース前レビュー）。**
    # 以前は 8 万字で 74 秒かかった。⚠ 上限は CI の揺れを見込んで緩めに置く（直した形は 0.01 秒）。
    def test_mask_urls_in_is_linear_on_long_runs
      ['A' * 80_000, '1a' * 40_000].each do |run|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        masked = @logger.mask_urls_in("curl -d #{run} https://h.example/?token=SECRET")

        assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2)
        assert_not_include(masked, 'SECRET')
      end
    end

    # ⚠ スキームの前に数字や `+.-` が付いた形も、従来どおり拾う。
    def test_mask_urls_in_masks_urls_after_a_leading_digit
      {
        '1http://h.example/?token=SECRET x' => '1http://h.example/?token=[FILTERED] x',
        'id=12https://h.example/?token=SECRET' => 'id=12https://h.example/?token=[FILTERED]',
        'see Ahttps://h.example/?token=SECRET' => 'see Ahttps://h.example/?token=[FILTERED]',
      }.each do |text, expected|
        assert_equal(expected, @logger.mask_urls_in(text), text)
      end
    end

    # 🔴 **復号した名前が不正な UTF-8 でも上げず、伏せる側に倒す（3.0.0 リリース前レビュー）。**
    def test_mask_urls_in_survives_an_undecodable_name
      ['https://h.example/?token%FF=1&access_token=SECRET', 'see https://h.example/?a%FF=1&token=SECRET ok'].each do |text|
        assert_not_include(@logger.mask_urls_in(text), 'SECRET', text)
      end
    end

    # ⚠ userinfo は**最後の** `@` まで。パスワードに `@` があっても丸ごと落とす。
    def test_mask_url_masks_a_password_containing_at_sign
      assert_equal('https://user:[FILTERED]@h.example/', @logger.mask_url('https://user:p@ss@h.example/'))
    end

    # 🔴 **`mask_url` の直呼びは引数まるごとを 1 つの URL とみなす (#712)。** 空白で切ると、値の後ろ半分や
    # パスワードが丸ごと出ていた（#700 からの退行）。⚠ 文中の URL（`mask_urls_in`）は従来どおり空白で切る。
    def test_mask_url_does_not_stop_at_spaces
      assert_equal('https://h.example/?token=[FILTERED]', @logger.mask_url('https://h.example/?token=SEC RETb'))
      assert_equal('https://u:[FILTERED]@h.example/', @logger.mask_url('https://u:p ssSECRETk@h.example/'))
      assert_equal(
        'see https://h.example/mulukhiya/webhook/[FILTERED] failed afterward',
        @logger.mask_urls_in('see https://h.example/mulukhiya/webhook/SECRET failed afterward'),
      )
    end

    # 🔴 **資格情報の値は `&` か `#` まで伏せる (#712)。** 値の中の `;名前=` / `?名前=` で切れて、後ろ半分が
    # 残っていた。⚠ 資格情報でない値の後ろの `;名前=` は従来どおり区切りとして読む。
    def test_mask_urls_in_masks_a_credential_value_up_to_the_ampersand
      {
        'https://h.example/?token=SEC;a=RETaq&b=1' => 'https://h.example/?token=[FILTERED]&b=1',
        'https://h.example/?token=SEC?a=RETaq#f' => 'https://h.example/?token=[FILTERED]#f',
        'https://h.example/?a=1;sig=SECRET' => 'https://h.example/?a=1;sig=[FILTERED]',
      }.each do |src, dest|
        assert_equal(dest, @logger.mask_urls_in(src))
        assert_equal(dest, @logger.mask_url(src))
      end
    end

    # 🔴 **入れ子の URL も伏せる (#712)。** クエリの値に入った URL のパス・クエリ・userinfo は、外側の URL の
    # 一部ではないので見ていなかった。⚠ エンコードした形も見る。伏せるものが無ければ 1 バイトも変えない。
    def test_mask_urls_in_masks_a_nested_url
      {
        'https://h.example/?u=https://x.example/mulukhiya/webhook/SECRET&a=1' =>
          'https://h.example/?u=https://x.example/mulukhiya/webhook/[FILTERED]&a=1',
        'https://h.example/?u=https%3A%2F%2Fx.example%2Fmulukhiya%2Fwebhook%2FSECRET' =>
          'https://h.example/?u=https%3A%2F%2Fx.example%2Fmulukhiya%2Fwebhook%2F[FILTERED]',
        'https://h.example/?u=https%3A%2F%2Fu%3ASECRET%40x.example%2F' =>
          'https://h.example/?u=https%3A%2F%2Fu%3A[FILTERED]%40x.example%2F',
        'https://h.example/?u=https%253A%252F%252Fx.example%252F%253Ftoken%253DSECRET' =>
          'https://h.example/?u=https%253A%252F%252Fx.example%252F%253Ftoken%253D[FILTERED]',
      }.each do |src, dest|
        assert_equal(dest, @logger.mask_urls_in(src))
      end
      # ⚠ 何重にもエンコードした無害な値は入れ子の URL ではない（Codex P2）。
      unchanged = [
        'https://h.example/?u=https://x.example/a/b&q=%41', 'https://h.example/?u=https%3a%2f%2fx.example%2fa',
        'https://h.example/?q=%2525252541', 'https://h.example/?q=%25252525252541&r=%3A'
      ]

      unchanged.each do |src|
        assert_equal(src, @logger.mask_urls_in(src))
      end
    end

    # 🔴 **`://` が見えるのに復号できない入れ子の値は伏せる（4.0.0 リリース前レビュー）。** 末尾に `%FF` を
    # 足すだけで素通りしていた。⚠ 段数は URL の段で数える（エンコードした 3 段の無害な値は残る）。
    def test_mask_urls_in_masks_an_undecodable_nested_url
      ['https://h.example/?u=https%3A%2F%2Fh%2F%3Ftoken%3DSECRET%FF', 'https://h.example/?u=https%3A%2F%2Fh%2Fmulukhiya%2Fwebhook%2FSECRET%ZZ'].each do |src|
        assert_equal('https://h.example/?u=[FILTERED]', @logger.mask_urls_in(src))
      end
      url = 'https://page.example/?return_to=/home'
      3.times {url = "https://h.example/?next=#{::URI.encode_www_form_component(url)}"}

      assert_equal(url, @logger.mask_urls_in(url))
    end

    # 🔴 **復号の段にも上限がある（#716 Codex P1）。** 数えずに再帰していたので、何千段も `%25` を重ねた値で
    # `SystemStackError` になり、`create_entry` ごと上がった。
    def test_mask_urls_in_caps_the_decoding_layers
      deep = "https://h.example/?u=#{'https%3A%2F%2Fx%2F%3Ftoken%3DSECRET'.gsub('%') {"%#{'25' * 20_000}"}}"

      assert_equal('https://h.example/?u=[FILTERED]', @logger.mask_urls_in(deep))
      assert_not_include(@logger.create_entry(url: deep), 'SECRET')
      shallow = "https://h.example/?u=#{'https%3A%2F%2Fx%2F%3Ftoken%3DSECRET'.gsub('%', '%2525')}"

      assert_not_include(@logger.mask_urls_in(shallow), 'SECRET')
      assert_include(@logger.mask_urls_in(shallow), 'x%25252F', '浅い段は値を残して伏せる')
    end

    # 🔴🔴 **エスケープの後ろに続く別の URL を飲み込まない（4.0.0 リリース前レビュー）。** `\X` を URL の一部と
    # みなしたため、JSON を二重にエンコードした文字列や `\n` の後ろの URL が前の URL に入り、伏せられなかった。
    # ⚠ 手前の区画が伏字で終わるとき（資格情報の値が URL）は、次の区画も値の続きとして伏せる。
    def test_mask_urls_in_splits_urls_joined_by_escapes
      [
        {'a' => 'https://other.example/x', 'b' => 'https://u:SECRET@k.example/'}.to_json.to_json,
        {'a' => 'https://h.example/?x=1', 'b' => 'https://k.example/mulukhiya/webhook/SECRET'}.to_json.to_json,
        'https://other.example/x\\nhttps://u:SECRET@k.example/',
        'https://h.example/?x=1\\nhttps://u:SECRET@k.example/',
        "cmd #{"https://h.example/a?token='https://SECRET.example/".shellescape} done",
      ].each do |src|
        assert_not_include(@logger.mask_urls_in(src), 'SECRET', src)
      end
      assert_equal(
        'see https://o.example/x\\nhttps://u:[FILTERED]@k.example/ ok',
        @logger.mask_urls_in('see https://o.example/x\\nhttps://u:SECRET@k.example/ ok'),
      )
    end

    # ⚠⚠ **入れ子は段数に上限がある (#712)。** 超えたら値ごと伏せる（安全側）。
    def test_mask_urls_in_caps_the_nesting_depth
      # ⚠ 生の `?u=` は値の中の `?u=` が区切りになり入れ子にならないので、エンコードを重ねる。
      url = 'https://x.example/?token=SECRET'
      8.times {url = "https://h.example/?u=#{::URI.encode_www_form_component(url)}"}
      masked = @logger.mask_urls_in(url)

      assert_not_include(masked, 'SECRET')
      # ⚠ 上限の段で、残りの値が丸ごと伏字になる（その段はエンコードされたまま）。
      # ⚠ 段数は URL の段で数える（4.0.0 リリース前レビュー）ので、上限は 5 段目。
      assert_match(/%2525253Fu%2525253D\[FILTERED\]\z/, masked)
      shallow = "https://h.example/?u=#{::URI.encode_www_form_component('https://x.example/?token=SECRET')}"

      assert_equal('https://h.example/?u=https%3A%2F%2Fx.example%2F%3Ftoken%3D[FILTERED]', @logger.mask_urls_in(shallow))
    end

    # ⚠ 設定の接頭辞の連続したスラッシュも畳む（4.0.0 リリース前レビュー: 外しても緑だった）。
    def test_mask_url_squeezes_configured_prefixes
      @logger.instance_variable_set(:@config, {'/logger/mask_url_paths' => ['/a//hook/']})

      ['https://h.example/a/hook/SECRET', 'https://h.example/a//hook/SECRET'].each do |src|
        assert_not_include(@logger.mask_url(src), 'SECRET', src)
      end
    end

    # 🔴 **連続したスラッシュも接頭辞として読む (#712)。** nginx の `merge_slashes`（既定で有効）を通ると、
    # `/mulukhiya//webhook/SECRET` は webhook に届く。⚠ 畳まないところは元のまま。
    def test_mask_urls_in_masks_a_path_with_doubled_slashes
      {
        'https://h.example/mulukhiya//webhook/SECRET' => 'https://h.example/mulukhiya//webhook/[FILTERED]',
        'https://h.example//mulukhiya/webhook//SECRET//x' => 'https://h.example//mulukhiya/webhook//[FILTERED]//x',
      }.each do |src, dest|
        assert_equal(dest, @logger.mask_urls_in(src))
        assert_equal(dest, @logger.mask_url(src))
      end
      assert_equal('https://h.example/a//b', @logger.mask_url('https://h.example/a//b'))
    end

    # 🔴 **名前は最初の `[` までで読み、先頭の括弧は中身を名前とみなす (#712)。** ⚠ 後者は伏せる側に倒す判断。
    def test_mask_urls_in_masks_a_bracketed_name
      ['https://h.example/?[token]=SECRET', 'https://h.example/?token[x]y=SECRET'].each do |src|
        assert_not_include(@logger.mask_urls_in(src), 'SECRET', src)
      end
      assert_equal('token', Masking.query_param_name('[token][x]'))
      assert_equal('sig', Masking.query_param_name('sig[]'))
    end

    # 🔴 **シェルのエスケープを外した形でも伏せる (#712)。** `sh -c` の文字列や `Shellwords.escape` の結果は
    # `\?token\=` の形で、区切りとして読めなかった。⚠ 伏せるものが無ければ元のまま。
    def test_mask_urls_in_masks_a_shell_escaped_url
      escaped = 'https://h.example/x?token=SECRET&a=b'.shellescape

      ["sh -c curl\\ #{escaped} done", escaped].each do |src|
        masked = @logger.mask_urls_in(src)

        assert_not_include(masked, 'SECRET', src)
        assert_include(masked, '[FILTERED]', '伏字は読める形で出す')
      end
      assert_not_include(@logger.mask_url(escaped), 'SECRET')
      # 🔴 **エスケープした空白も同じシェルの単語の中身（Codex P1）。** 値の後ろ半分・パスワードが残っていた。
      secrets = ['RETb', 'SECRET']
      # ⚠ 引用符・`<>`・バッククォートも同じ（Codex P1・2 巡目）。
      urls = ['https://h.example/x?token=SEC RETb', 'https://u:p ssSECRET@h.example/']
      # ⚠ 改行は `'\n'` の形になる（Codex P1・3 巡目）。
      ["'", '"', '<', '>', '`', '|', '{', "\n", "\t"].each do |char|
        urls.push("https://h.example/x?token=SEC#{char}RETb", "https://u:pSEC#{char}SECRET@h.example/")
      end
      urls.each do |url|
        ["sh -c curl #{url.shellescape} done", url.shellescape].each do |src|
          masked = @logger.mask_urls_in(src)

          secrets.each {|v| assert_not_include(masked, v, src)}
        end
      end
      # 🔴 **authority の 1 文字目のエスケープも受ける（Codex P1・5 巡目）。**
      ['https://[::1]/?token=SECRET', 'https://[::1%25eth0]/?token=SECRET', "https://'u:pSECRET@h.example/"].each do |url|
        assert_not_include(@logger.mask_urls_in("cmd #{url.shellescape} done"), 'SECRET', url)
      end
      # ⚠ 生のまま伏せて足りるときは、エスケープし直さない。
      assert_equal('https://h.example/a?x=1\\&sig=[FILTERED]', @logger.mask_urls_in('https://h.example/a?x=1\\&sig=SECRET'))
      # 🔴 **NUL が残っても例外を上げない（4.0.0 リリース前レビュー）。** `Shellwords.escape` は NUL で上がる。
      assert_not_include(@logger.mask_urls_in("https://h.example/x\0y\\?token\\=SECRET"), 'SECRET')
      plain = 'https://h.example/a b/x?a=1&b=2'.shellescape

      assert_equal("sh -c #{plain}", @logger.mask_urls_in("sh -c #{plain}"))
    end

    def test_create_message_masks_signed_url_query
      SIGNED_URLS.each do |name, url|
        assert_include(Masking::MASK_QUERY_PARAMS, name)
        field = @logger.create_message(url:)[:url]
        # ⚠ 文中の形は 2.4.0 までの `TooLargeError` のメッセージ（#689 で URL を外した）。
        # 利用側の例外は今もこの形で URL を埋めるので、文中でも落ちることを見る。
        embedded = @logger.create_message(message: "Response body exceeded 100 bytes (#{url})")[:message]

        [field, embedded].each do |masked|
          assert_not_include(masked, 'SECRET', name)
          assert_include(masked, '[FILTERED]', name)
          assert_include(masked, 'AKIDEXAMPLE', '隣のパラメータ（鍵の識別子など）は残す')
        end
      end
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

    # 🔴🔴 **Slack / Discord の webhook は、接頭辞から後ろを全部伏せる (#704)。** 秘密が接頭辞の
    # 1 セグメント先とは限らない（Slack は 3 セグメントめ）ので、`/logger/mask_url_paths` では
    # 塞がらなかった。⚠ 接頭辞とクエリは残す。
    def test_mask_url_masks_webhook_paths_by_host
      {
        'https://hooks.slack.com/services/T000/B000/XXXXSECRET' =>
          'https://hooks.slack.com/services/[FILTERED]',
        'https://discord.com/api/webhooks/123/XXXXSECRET?wait=true' =>
          'https://discord.com/api/webhooks/[FILTERED]?wait=true',
        'https://ptb.discord.com/api/v10/webhooks/123/XXXXSECRET' =>
          'https://ptb.discord.com/api/v10/webhooks/[FILTERED]',
        'https://discordapp.com/api/v6/webhooks/123/XXXXSECRET/slack' =>
          'https://discordapp.com/api/v6/webhooks/[FILTERED]',
        # ⚠ ホストの大文字・ポート・末尾の `.`・userinfo、連続したスラッシュ、パスの大文字。
        'https://HOOKS.Slack.com.:443/services//T000/B000/XXXXSECRET' =>
          'https://HOOKS.Slack.com.:443/services//[FILTERED]',
        'https://u:p@canary.discord.com/API/Webhooks/123/XXXXSECRET' =>
          'https://u:[FILTERED]@canary.discord.com/API/Webhooks/[FILTERED]',
      }.each do |src, expected|
        assert_equal(expected, @logger.mask_url(src), src)
      end
    end

    # ⚠ **ホストが違えば触らない (#704)。** `/services/` だけで判定すると無関係な URL を巻き込む。
    # ⚠ 接頭辞で終わる URL（後ろが空）も、伏せるものが無いので触らない。
    def test_mask_url_leaves_other_hosts_alone
      [
        'https://example.com/services/T000/B000/XXXXSECRET',
        'https://evilhooks.slack.com/services/T000/B000/XXXXSECRET',
        'https://hooks.slack.com.example.com/services/T000/B000/XXXXSECRET',
        'https://discord.com/api/v10/channels/123/messages',
        'https://hooks.slack.com/services/',
      ].each do |src|
        assert_equal(src, @logger.mask_url(src), src)
      end
    end

    # ⚠ 文中の URL・シェルのエスケープ形・`slack:` 欄・例外メッセージでも伏せる (#704)。
    # 🔴 `Slack.broadcast` は失敗した hook を `slack:` に、`HTTP#log` は `url:` に出す。
    def test_create_message_masks_webhook_urls
      url = 'https://hooks.slack.com/services/T000/B000/XXXXSECRET'
      message = @logger.create_message(
        slack: url,
        url: 'https://discord.com/api/webhooks/123/XXXXSECRET',
        error: StandardError.new("Bad response 404 (#{url})"),
      )

      assert_not_include(message.to_json, 'XXXXSECRET')
      assert_include(message[:slack], 'https://hooks.slack.com/services/', '接頭辞は残す')
      assert_not_include(@logger.mask_urls_in("curl #{url.shellescape} failed"), 'XXXXSECRET')
    end

    # ⚠ 設定 `/logger/mask_url_host_paths` で足せる。既定は残る（減らせない）。
    # ⚠ `https://` 付きでも読み、パスの無い項目はパス全体を伏せる。
    def test_mask_url_host_paths_merge_with_the_config
      @logger.instance_variable_set(:@config, {
        '/logger/mask_url_host_paths' => ['https://Push.Example.com/api/push/', 'whole.example.com'],
      })

      assert_equal('https://push.example.com/api/push/[FILTERED]',
        @logger.mask_url('https://push.example.com/api/push/XXXXSECRET'))
      assert_equal('https://whole.example.com/[FILTERED]',
        @logger.mask_url('https://whole.example.com/a/XXXXSECRET'))
      assert_equal('https://hooks.slack.com/services/[FILTERED]',
        @logger.mask_url('https://hooks.slack.com/services/T/B/XXXXSECRET'), '既定は残すこと')
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

    # 🔴 **zone id 付きの IPv6 リテラルもマスクされること (#609)。**
    #
    # `Addressable::URI.parse('https://[fe80::1%25eth0]/...')` は
    # `InvalidURIError` を上げ、`mask_url` の rescue が**元の文字列をそのまま
    # 返して**いた。⚠⚠ **走査（`URL_IN_TEXT_PATTERN`）に `%` を通すだけでは
    # 出力が 1 文字も変わらない** — 走査は当たるが `mask_url` が rescue する。
    def test_create_message_masks_url_with_zone_id
      [
        'https://[fe80::1%25eth0]/?token=SECRET',
        # ⚠ RFC 6874 の綴りは `%25` だが、**生の `%` もログには出る**
        # （アプリが文字列として組み立てるため）。
        'https://[fe80::1%eth0]/?token=SECRET',
        'https://[fe80::1%25eth0]:8443/a?token=SECRET&x=1',
        # 🔴 **ZoneID は unreserved だけではない（Codex P1）。**
        # `ZoneID = 1*( unreserved / pct-encoded )` なので、区切りの後にも
        # パーセントが来る。⚠ 2 つ目の `%` で切ると走査が当たらず素通りする。
        'https://[fe80::1%25eth%30]/?token=SECRET',
        'https://[fe80::1%25%65%74%68%30]/?token=SECRET',
        'https://user:pw@[fe80::1%25eth0]/?token=SECRET',
        # ⚠ パスの接頭辞で落とす経路も通ること。
        'https://[fe80::1%25eth0]/mulukhiya/webhook/SECRET',
      ].each do |url|
        masked = @logger.create_message(url:)[:url]

        assert_not_include(masked, 'SECRET', url)
        assert_include(masked, '[FILTERED]', url)
      end
    end

    # ⚠⚠ **外した zone id は戻すこと。** ホストは診断に要る（どの経路で出たか）。
    def test_create_message_keeps_zone_id_in_masked_url
      masked = @logger.create_message(url: 'https://[fe80::1%25eth0]:8443/a?token=SECRET')[:url]

      assert_equal('https://[fe80::1%25eth0]:8443/a?token=[FILTERED]', masked)
    end

    # 🔴 **ホストより手前は長さが変わる。** userinfo のパスワードを伏せると
    # `LONGPASSWORD` が `[FILTERED]` になるので、**元の位置へ戻すと zone id が
    # ずれる**。⚠ 位置ではなくホストの綴りで戻していること。
    def test_create_message_keeps_zone_id_after_password_masking
      url = 'https://user:LONGPASSWORD@[fe80::1%25eth0]/x?token=SECRET'

      masked = @logger.create_message(url:)[:url]

      assert_equal('https://user:[FILTERED]@[fe80::1%25eth0]/x?token=[FILTERED]', masked)
    end

    # ⚠ 文字列の**途中**に埋まった形でも拾うこと（例外メッセージ経路）。
    def test_create_message_masks_embedded_zone_id_url
      masked = @logger.create_message('connect failed https://[fe80::1%25eth0]/?token=SECRET retry')

      assert_not_include(masked, 'SECRET')
      assert_include(masked, 'https://[fe80::1%25eth0]/', 'ホストは残す')
      assert_include(masked, 'retry', '後続の文字列は残す')
    end

    # ⚠⚠ **落とすものが無ければ 1 バイトも変えないこと。** zone id を外して
    # 組み立て直した文字列を返すと、ここが崩れる。
    def test_create_message_keeps_untouched_zone_id_url_identical
      [
        'https://[fe80::1%25eth0]/feed',
        'https://[fe80::1%eth0]:8443/',
      ].each do |url|
        assert_equal(url, @logger.create_message(url:)[:url])
      end
    end

    # 🔴 **壊れたバイト列でも `mask_url` が上げないこと (#609 / #518)。**
    #
    # ⚠⚠ `mask_url` で上げると `create_message` の rescue まで飛び、**mask ごと素通りして
    # mask_fields のキーまで平文で出る**。⚠ `mask_url` は public で、利用側が直接呼ぶ
    # （Sentry の `before_send`）。#700 でパースをやめた後も、正規表現の時点で上がりうるので固定しておく。
    def test_mask_url_survives_broken_bytes
      [
        "https://x.example/?token=SECRET#{BROKEN_BYTES}",
        'https://x.example/?token=SECRET'.encode('UTF-16LE'),
      ].each do |url|
        assert_nothing_raised(url.encoding.name) do
          @logger.mask_url(url)
        end
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
        # ⚠ クエリやヘッダの綴りのまま（文字列・大文字混じり）で来る (#693)。パース済みの
        # クエリ（`params`）や `headers` を Hash のまま出したとき。
        'X-Amz-Security-Token', 'X-Amz-Signature', 'X-Goog-Signature', :'x-amz-signature',
        # ⚠ #701 で足した名前。
        'X-Api-Key', 'Api-Key', :id_token, 'Security-Token', 'q-signature',
        'x-cos-security-token', 'x-oss-security-token', 'x-oss-signature',
        # ⚠ 大文字小文字で判定を変えないこと（#585 の回帰も兼ねる）。
        :Authorization, :Access_Token, :TOKEN
      ].each do |key|
        message = @logger.create_message(probe: 'mask', key => 'S3CRET')

        assert_equal({probe: 'mask'}, message, key.to_s)
        # ⚠ 設定ではなく既定（定数）に在ること。利用側へ届くのは定数のほう (#693)。
        assert_include(Masking::MASK_FIELDS, key.to_s.downcase)
      end
    end

    # ⚠⚠ **合成後の一覧そのものを要る利用側がある。**`mask` は当たったキーを落とす
    # ので、**「伏せたことを見せる」出力には使えない**（`pooza/makoto2` の
    # `makoto config` は `(masked)` と表示する）。🔴 **公開しないと利用側が同等品を
    # 書き、#586 で広げた既定が届かない。**
    def test_mask_fields_is_public
      assert_true(@logger.respond_to?(:mask_fields), '利用側から呼べること')
      # ⚠ 既定が入っていること（設定だけを見ていたら通らない）。
      assert_include(@logger.mask_fields, 'client_secret')
      assert_include(@logger.mask_fields, 'refresh_token')
      # ⚠ 小文字に揃っていること（`mask_field?` が downcase して照合するため）。
      assert_empty(@logger.mask_fields.reject {|field| field == field.downcase})
    end

    # 🔴🔴 **公開した口を「マスクを外す口」にしない (#625 の Codex P2)。**
    # `masking_list` はメモ化した現物を返すので、凍らせないと利用側の
    # `delete` でロガーのマスクがその場で外れる。⚠ 実測では
    # `mask_fields.delete('password')` の直後から `password:` が平文で出た。
    #
    # ⚠⚠ **`frozen?` だけでは足りない。** Set の凍結は中の Hash まで効いて
    # いる必要があるので、**実際にマスクが生きていること**まで測る。
    def test_mask_fields_cannot_be_weakened_by_callers
      assert_true(@logger.mask_fields.frozen?, '利用側へ渡す一覧は凍っていること')
      assert_raise(FrozenError) {@logger.mask_fields.delete('password')}
      assert_equal({probe: 'mask'}, @logger.create_message(probe: 'mask', password: 'S3CRET'))
    end

    # ⚠⚠ **クエリと同じ広さにはしない (#586)。** `code` / `i` / `key` はクエリの
    # パラメータ名としては資格情報だが、**Hash のキーとしては無関係な値が普通に
    # 入る**。広げすぎると診断に要る値まで消える。
    def test_create_message_keeps_generic_fields
      message = @logger.create_message(code: 404, key: 'name', i: 3)

      assert_equal({code: 404, key: 'name', i: 3}, message)

      # ⚠ 署名系でも、汎用名はクエリ側にだけ置く (#690 / #693)。
      generic = {sig: 'x', signature: 'footer', hm: 1, jwt: 'header'}

      assert_equal(generic, @logger.create_message(generic))
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
