# frozen_string_literal: true

require 'addressable/uri'
require 'securerandom'
require 'shellwords'

module Ginseng
  # ログ・外部送信の直前に資格情報を落とすための一式 (#582)。
  #
  # ⚠⚠ **マスクの正本はここ 1 か所にする。** 利用側で同等品を書くと、対象の列が
  # 分かれて必ずズレる。`/logger/mask_fields` / `/logger/mask_query_params` /
  # `/logger/mask_url_paths` を唯一の正本に保つため、`mask` / `mask_url` /
  # `mask_urls_in` は public にしてある（実例: Sentry の `before_send`
  # ＝ pooza/tomato-shrieker#1467）。
  #
  # ⚠ **include する側が `@config` を持つこと。**
  module Masking
    # ⚠ URL のパスの接頭辞まわりは別ファイルへ出してある (#610)。
    # **`@config` を持つ側に混ぜる形は変わらない**ので、利用側の見え方は同じ。
    include UrlPath
    # ⚠ クエリとフラグメント、入れ子の URL も別ファイル (#712)。形は `UrlPath` と同じ。
    include UrlQuery

    FILTERED = '[FILTERED]'

    # エンコードし直した伏字を、読める形へ戻すための綴り（入れ子の URL。#712）。
    FILTERED_ENCODED = ::URI.encode_www_form_component(FILTERED).freeze

    # Hash のキーに現れたら値ごと落とす資格情報の既定値。
    # config の `/logger/mask_fields` で**足せる**（⚠ 減らせない。masking_list 参照）。
    #
    # ⚠ **既定を空にしないこと。** 設定を書き忘れたアプリが守られる状態を既定に
    # する（mask_query_params と同じ判断）。
    #
    # 🔴 **mask_query_params より狭かった (#586)。** URL のクエリに
    # `access_token=` が出れば落ちるのに、Hash のキーが `access_token:` だと
    # 素通りしていた。**同じ資格情報が、通り道によって守られたり守られなかったり
    # する**状態だった。
    #
    # ⚠⚠ **`code` / `i` / `key` は入れない。** クエリのパラメータ名としては
    # 資格情報だが、**Hash のキーとしては無関係な値が普通に入る**（`key` は
    # 汎用名、`code` はステータスコードやエラーコード）。クエリと同じ広さが
    # 正しいとは限らない。⚠ `sig` / `signature` / `hm` / `jwt`（#690 / #693）も
    # クエリ側にだけ在る（理由は `MASK_QUERY_PARAMS`）。
    MASK_FIELDS = [
      'access_token',
      'api_key',
      'apikey',
      # ⚠ HTTP ヘッダの綴りそのもので、資格情報以外の用途が無い。
      'authorization',
      'client_secret',
      'password',
      'refresh_token',
      'secret',
      'token',
      # ⚠ 署名付き URL の名前のうち、**Hash のキーとしても他の用途が無いもの**（#693）。
      # `sig` / `signature` は入れない（無関係な値が普通に入る）。
      'x-amz-security-token',
      'x-amz-signature',
      'x-goog-signature',
      # ⚠ 同じ判断で足した名前（#701）。ヘッダの綴り（`X-Api-Key`）・OIDC の `id_token`・
      # Alibaba OSS / Tencent COS の署名。⚠⚠ `auth` / `hmac` は入れない（Hash のキーとしては
      # 設定値やアルゴリズム名が普通に入る）。
      'api-key',
      'id_token',
      'q-signature',
      'security-token',
      'x-api-key',
      'x-cos-security-token',
      'x-oss-security-token',
      'x-oss-signature',
    ].freeze

    # URL のクエリに現れたら落とす資格情報パラメータの既定値。
    # config の `/logger/mask_query_params` で**足せる**（⚠ 減らせない）。
    #
    # 🔴 **署名付き URL の名前を持っていなかった (#690)。** 第三者が渡す URL
    # （webhook の `image_url` など）は署名付きのことがあり、**署名はその 1 オブジェクトへの
    # 期限付きの持参人払い**。⚠ 照合は小文字化して行うので、`X-Amz-Signature` も
    # CloudFront の `Signature` もここの綴りで一致する。
    #
    # ⚠ **鍵の識別子（`X-Amz-Credential` / `Key-Pair-Id`）は入れない。** 秘密ではなく、
    # どの鍵の URL かはログに残したい。
    # ⚠ **署名付き URL に限らない名前も足した (#693)。** `hm`（Discord 添付の HMAC）と
    # `jwt`（GitHub の private 添付）は webhook の `image_url` に現実に来る。
    # `authorization` は `MASK_FIELDS` に在るのにここに無かった（Backblaze B2 は
    # クエリで受ける。#586 が塞いだ非対称の逆向き）。
    # ⚠⚠ **`sig` / `signature` / `hm` / `jwt` は `MASK_FIELDS` に足さない。** Hash のキーとしては
    # 無関係な値が普通に入る（`code` / `key` と同じ判断）。⚠ `x-amz-*` / `x-goog-*` は
    # Hash のキーとしても他の用途が無いので、あちらにも在る（#693）。
    #
    # ⚠⚠ **`HTTP::RedirectGuard` が同じ一覧を「資格情報か」の判定に使う。** ここへ足すと、
    # ガードを挿した口では、その名前をクエリに持つ GET / HEAD がリダイレクトを追わず、
    # 🔴 **3xx が `GatewayError` になる**。⚠ 呼び出し側が `follow_redirects:` を
    # 明示していれば従来どおり。
    #
    # ⚠ **#701 で足した名前:** `api-key` / `x-api-key` / `auth`（Firebase など）/ `id_token`（OIDC）/
    # `hmac`、Alibaba OSS（`security-token` / `x-oss-*`）、Tencent COS（`q-signature` /
    # `x-cos-security-token`）、Akamai（`hdnts` / `__token__`）。⚠⚠ `s`（imgix）/ `t`（Slack）/
    # `oh`（Facebook）は汎用すぎるので入れない。
    MASK_QUERY_PARAMS = [
      '__token__',
      'access_token',
      'api-key',
      'api_key',
      'apikey',
      'auth',
      'authorization',
      'client_secret',
      'code',
      'hdnts',
      'hm',
      'hmac',
      'i',
      'id_token',
      'jwt',
      'key',
      'password',
      'q-signature',
      'refresh_token',
      'secret',
      'security-token',
      'sig',
      'signature',
      'token',
      'x-amz-security-token',
      'x-amz-signature',
      'x-api-key',
      'x-cos-security-token',
      'x-goog-signature',
      'x-oss-security-token',
      'x-oss-signature',
    ].freeze

    # URL の**パス**に現れたら次の 1 セグメントを落とす接頭辞の既定値。
    # config の `/logger/mask_url_paths` で**足せる**（⚠ 減らせない）(#580)。
    #
    # ⚠⚠ **クエリと違い、パスは「キー名」で判定できない。** モロヘイヤの
    # webhook は `POST /mulukhiya/webhook/{digest}` で **パスそのものが
    # 資格情報**なので、接頭辞を知っている側が申告するほかない。
    #
    # ⚠ **既定を空にしないこと。** mask_query_params と同じく「設定が無ければ
    # 既定へ倒す。マスクしない方向へは倒さない」。モロヘイヤ配下のアプリが
    # 設定を書き忘れても守られる状態を既定にする。
    MASK_URL_PATHS = [
      '/mulukhiya/webhook/',
    ].freeze

    URL_PATTERN = %r{\A[a-z][a-z0-9+.-]*://}i

    # URL を `scheme://` / authority / パス / 残り（クエリとフラグメント）に分ける (#700)。
    # ⚠ **必ず一致する**（`URL_PATTERN` に当たった文字列なら）。パースではないので、
    # 読めない URL という状態が無い。
    #
    # ⚠⚠ **authority とパスは空白で終える（Codex P2）。** `url:` 欄以外にも、URL で始まって
    # 文が続く文字列がある。🔴 パスを空白の先まで取ると、`…/webhook/SECRET failed afterward`
    # の**後ろの文ごと**伏字になっていた（パスのマスクは次の `/` までを落とす）。
    # ⚠ クエリは残り（`rest`）に入るので、値の中の空白（`?x=a b&sig=`）は従来どおり越える。
    URL_PARTS_PATTERN = %r{
      \A (?<scheme>[a-z][a-z0-9+.-]*://) (?<authority>[^/?\#\s]*) (?<path>[^?\#\s]*) (?<rest>.*) \z
    }mix

    # `URL_PARTS_PATTERN` の、**引数まるごとが URL** のとき（`mask_url` の直呼び）の形 (#712)。
    # 🔴 空白で切ると `u:p ssSECRET@h` のパスワードが丸ごと出ていた（#700 からの退行）。
    # ⚠ 空白で切るのは「URL の後ろに文が続く」かもしれない `mask_urls_in` の側だけ。
    URL_WHOLE_PARTS_PATTERN = %r{
      \A (?<scheme>[a-z][a-z0-9+.-]*://) (?<authority>[^/?\#]*) (?<path>[^?\#]*) (?<rest>.*) \z
    }mix

    # IPv6 リテラルの zone id (#609)。⚠ RFC 6874 の綴りは `%25eth0` だが、
    # **生の `%eth0` もログには出る**（アプリが文字列として組み立てるため）。
    #
    # ⚠⚠ **ZoneID は unreserved だけではない。** RFC 6874 は
    # `ZoneID = 1*( unreserved / pct-encoded )` なので、`%25eth%30` のように
    # **区切りの後にもパーセントが来る**（Codex P1）。unreserved だけを許すと
    # 2 つ目の `%` で切れ、**走査が当たらず素通りする**（実測でトークンが残った）。
    URL_ZONE_ID_PATTERN = /%(?:25)?(?:[0-9a-z._~-]|%[0-9a-f]{2})+/i

    # 文字列の**途中**に埋まった URL を拾う (#582)。⚠ URL_PATTERN と違って錨が
    # 無い。アプリは `"Invalid feed #{id} (#{uri}) ..."` のように例外メッセージへ
    # URL を埋めるので、そこを拾えないと資格情報が素通りする。
    #
    # 🔴 **角括弧はホストの位置でだけ許す (#601)。** 一律に除外していたため
    # `https://[::1]/?token=SECRET` は**一致そのものが起きず**、IPv6 リテラルの
    # URL だけマスクを素通りしていた。⚠⚠ **一律に許すと行き過ぎて食う** —
    # Markdown の `[text](url)` や `[url]` で括った形が壊れる。
    #
    # ⚠⚠ **userinfo を飛ばしてからホストを見ること（Codex P1）。** `://` の直後に
    # 角括弧を要求すると、`https://user:pass@[::1]/?token=SECRET` は
    # **`https://user:pass@` だけ**に一致して `[` で切れ、**クエリが mask_url に
    # 届かない**（実測でトークンが残った）。
    #
    # 🔴🔴 **クエリの途中で切れると、その後ろが丸ごと素通りする (#700)。** `\` `^` `{` `}` `|`
    # で切っていたため `?x=^&sig=SECRET` は `sig` に届かず、`sig=SEC|RET` は `RET` が残った。
    # ⚠ **クエリとフラグメントでだけ**それらを許す（パスは従来どおり）。⚠⚠ 角括弧は
    # **対になった `[...]`（`sig[]=`）か、閉じない `[`** だけ — 閉じ括弧を一律に許すと
    # Markdown の `[url](...)` や `[url]` を食う（上記）。⚠ 閉じていない IPv6 の `[`
    # （`https://[::1/a?sig=`）もホストとして受ける。
    # ⚠ 空白・引用符・`<>` では従来どおり切る（文中の URL の終わりの目印なので）。
    # まるごと URL の文字列は `mask_urls_in` が走査せずに受ける。
    #
    # 🔴🔴 **スキームは英数字の連続の先頭からだけ探す（3.0.0 リリース前レビュー）。** 錨が無いと、
    # 長い英数字の連続の中で開始位置をずらすたびに連続の終わりまで読み直し、**入力長の 2 乗**かかった
    # （8 万字で 74 秒。悪意あるサーバーの 20KB の応答行で GET 1 回が 8.9 秒）。⚠ 連続の先頭の数字や
    # `+.-`（`1http://`）は `lead` に取り、`mask_urls_in` で外して扱う（以前はスキームの位置から拾えていた）。
    # ⚠ スキームの残りは独占的に取る — 後ろに `://` が無ければ、その連続は 1 回で諦める。
    #
    # 🔴 **パスの中のエスケープ（`\?` `\=`）も URL の一部とみなす (#712)。** `sh -c` に渡す文字列や
    # `Shellwords.escape` の結果は `https://h/x\?token\=SECRET` の形で、`\` で切ると `?token=` が
    # 走査に届かなかった。
    # 🔴🔴 **`\` とその次の 1 文字は、何であっても URL の一部とみなす（Codex P1 ×2）。** エスケープした
    # 空白・引用符・`<>`・バッククォートは同じシェルの単語の中身なので、そこで切ると `?token\=SEC\ RET` の
    # `RET` や、`u:p\'SECRET@` のパスワードが丸ごと残った（1 巡目に空白だけ足して、2 巡目に引用符で同じ形が
    # 出た）。⚠ エスケープしていない空白・引用符・`<>` はこれまでどおり URL の終わりの目印。
    # ⚠ JSON を文字列に埋めた形（`\"`）でも URL が後ろへ伸びるが、変わるのは伏せるものがある URL だけ。
    # 🔴 **改行だけは `'\n'`（引用符で囲む）になる（Codex P1・3 巡目）。** `Shellwords.escape` が `\X` 以外で
    # 表すのはこの 1 つだけ（全 ASCII 文字で確かめた）なので、これで `Shellwords.escape` の出力は全部覆う。
    URL_IN_TEXT_PATTERN = %r{
      (?<![a-z0-9+.-]) (?<lead>[0-9+.-]*) [a-z][a-z0-9+.-]*+ ://
      (?:[^\s<>"'`\\^{}|\[\]/?\#]*@)?
      (?:\[[0-9a-f:.]+(?:#{URL_ZONE_ID_PATTERN})?\]? | [^\s<>"'`\\^{}|\[\]])
      (?: [^\s<>"'`\\^{}|\[\]?\#] | \\. | '\n' )*
      (?: [?\#] (?: \\. | '\n' | \[[^\[\]\s<>"'`]*\] | [^\s<>"'`\]] )* )?
    }ix

    # URL の末尾に付きがちで、URL 本体ではないことが多い文字。
    TRAILING_PUNCTUATION = /[).,;:!?]+\z/

    # クエリの名前を、サーバーが読む形に揃える (#700)。⚠ `RedirectGuard` と共有する
    # （「マスクの対象か」と「資格情報か」は同じ判断）。
    # ⚠ 復号できない名前は `ArgumentError` を上げる。**呼び出し側で安全側へ倒す。**
    #
    # 🔴 **名前は Rack と同じく最初の `[` までで読む (#712)。** `[token]=` は Rack では `token` と
    # 読まれるのに、末尾の添字を外すだけでは空の名前になり素通りしていた。⚠ 先頭が `[` のときは、
    # 最初の括弧の中身を名前とみなす。
    def self.query_param_name(key)
      name = ::URI.decode_www_form_component(key.to_s).strip
      if name.start_with?('[') && (close = name.index(']', 1))
        name = name[1...close]
      else
        name = name.sub(/\[.*\z/m, '')
      end
      return name.strip.downcase
    end

    # ログ出力用にマスクした複製を返す。
    #
    # ⚠ 引数は変更しないこと。以前は arg.delete / arg[k]= で入力そのものを
    # 書き換えており、ログに渡しただけで呼び出し元の Hash から mask_fields の
    # キーが消えていた（mulukhiya で Sinatra の params が壊れた実例あり）。
    # 加えて、文字列キーの Hash では symbolize_keys した複製を回しながら元の
    # arg を delete するためマスクが効かず、シンボルキーが二重に生えたうえで
    # 素の値がログに出ていた (#478)。
    def mask(arg)
      case arg
      in Hash
        entries = arg.symbolize_keys.reject {|k, v| v.to_s.empty? || mask_field?(k)}
        return entries.transform_values {|v| mask(v)}
      in Array
        return arg.reject {|v| v.to_s.empty?}.map {|v| mask(v)}
      in String
        return mask_urls_in(arg)
      else
        return arg
      end
    end

    # 文字列の中に埋まった URL を 1 つずつ mask_url へ通す (#582)。
    #
    # 🔴 **mask_url だけでは効かない場所がある。** URL_PATTERN は `\A` に錨が
    # あるので、`"Invalid feed x (https://.../mulukhiya/webhook/<digest>) ..."`
    # のような**例外メッセージ**は素通りしていた。ログにも Sentry にも同じ形で
    # 出る（pooza/tomato-shrieker#1467）。
    def mask_urls_in(text)
      text = utf8_compatible(text)
      # ⚠ HTTP#log は毎リクエスト通る。当たらない文字列で走査しない。
      return text unless text.include?('://')
      # ⚠⚠ **不正なバイト列は gsub の時点で ArgumentError を上げる (#518 / #587)。**
      # ここで落とすと利用側が rescue を書くことになり、**マスクの正本を 1 か所に
      # 保つ**という #580 の前提が崩れる（pooza/tomato-shrieker に実際に rescue が
      # 生えていた）。
      #
      # 🔴 **「rescue して元の文字列を返す」にしないこと。**
      # それだと URL の資格情報が平文で残る（v1.20.0 が実際にそうだった）。
      # **scrub してからマスクする** — ログ経路（create_entry）と同じ倒し方。
      text = text.scrub('?') unless text.valid_encoding?
      # ⚠⚠ **まるごと 1 つの URL なら走査しない (#700)。** `url:` 欄は URL そのものなので、
      # 文中の URL の終わりの目印（空白・引用符・`<>`）で切る理由が無い。🔴 切ると
      # `?x="1"&sig=SECRET` の `sig` が素通りしていた。
      return mask_url_core(text, text: true) if whole_url?(text)
      return text.gsub(URL_IN_TEXT_PATTERN) do |url|
        lead = Regexp.last_match[:lead]
        core, trailing = split_trailing_punctuation(url.delete_prefix(lead))
        "#{lead}#{mask_url_core(core, text: true)}#{trailing}"
      end
    end

    private

    # ⚠⚠ **ASCII 非互換なエンコーディングは `include?` の時点で落ちる (#591)。**
    def utf8_compatible(text)
      # UTF-16 / UTF-32 は `Encoding::CompatibilityError` を上げるので、走査より
      # 先に UTF-8 へ寄せる（`Logger#scrub` と同じ倒し方）。
      #
      # 🔴 **ASCII 互換なものは変換しないこと。** `ASCII-8BIT` には妥当な UTF-8 が
      # 入っていることがあり（Sequel / SQLite がこの形で返す。
      # pooza/ginseng-fediverse#265）、`encode` に通すと**中身を潰す**。実測でも
      # 落ちるのは ASCII 非互換のときだけだった（Shift_JIS / ASCII-8BIT は通る）。
      unless text.encoding.ascii_compatible?
        text = begin
          text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
        rescue EncodingError
          # ⚠⚠ **dummy encoding には変換器が無い。** `UTF-7` / `ISO-2022-JP-2` は
          # `invalid:` / `undef:` では救えず `ConverterNotFoundError` を上げる
          # （Codex P2。実測で確認）。`Logger#scrub` と同じく、**バイト列を UTF-8 と
          # みなして scrub する** — 中身は読みにくくなるが、**マスクは効く**。
          text.dup.force_encoding(Encoding::UTF_8).scrub('?')
        end
      end
      return text
    end

    # `scheme://` で始まり、ほかに URL を含まない文字列か (#700)。
    # ⚠ 後ろに文が続いてもよい（値は空白で終わるので、文までは伏せない）。
    def whole_url?(text)
      return text.match?(URL_PATTERN) && text.index('://', text.index('://') + 3).nil?
    end

    # 設定のリストを引く。⚠⚠ **設定は既定を置き換えない。既定と合成する (#586)。**
    #
    # 🔴 **上書きだったころ、広げた既定はどこにも届かなかった。** 2026-08-28 の
    # 実測では利用側 3 本とも `/logger/mask_fields` を自前で列挙しており、
    # **`tomato-shrieker` は既定にある `token` を落としていた**（列挙しなおした
    # ときに漏れた）。⚠ 設定は「足すもの」であって、**マスクを外す手段ではない**。
    #
    # ⚠ 既定から外したいものが出たら、**この gem の既定を直す**（利用側の 1 本の
    # 都合で全体のマスクを緩めない）。
    #
    # ⚠⚠ **メモ化を config の変更に追随させること (#592)。** `Config#reload` は
    # テスト専用ではなく**アプリの UI から呼ばれる**（pooza/mulukhiya-toot-proxy の
    # `ui_controller`）。単純な `||=` だと「マスク対象を足して reload した」のに
    # **走っているロガーが古い一覧のまま資格情報を出し続ける** — 直したつもりで
    # 直っていない、という一番たちの悪い形になる（Codex P2）。
    #
    # ⚠ **毎回作り直さないこと。** `mask_field?` はログ 1 行のキーの数だけ呼ばれる。
    # `@config` の読み出しはメモ化前と同じコストなので、**元の配列が変わったときだけ**
    # 作り直す。
    def masking_list(key, default)
      configured = begin
        @config[key]
      rescue ConfigError
        nil
      end
      @masking_lists ||= {}
      cached = @masking_lists[key]
      # ⚠ **memo の鍵は合成後ではなく設定そのもの。** 合成を毎回作ると
      # `mask_field?` の呼び出し（ログ 1 行のキーの数だけ走る）ごとに配列を
      # 割り当てることになる。
      return cached.last if cached && cached.first == configured
      # 🔴🔴 **凍らせること。メモ化した現物をそのまま返している** ので、
      # 受け取った側が `delete` するとロガーのマスクがその場で外れる
      # （`mask_fields` を公開した #625 の Codex P2。実測で
      # `logger.mask_fields.delete('password')` の直後から
      # `{password: "S3CRET"}` が平文で出た）。
      #
      # ⚠⚠ **設定が「足すだけ」なのと同じ原則**（上記）— **外す手段を
      # 公開の口から作らない**。⚠ 複製を返す形にはしない: `mask_field?` は
      # ログ 1 行のキーの数だけ呼ばれるので、毎回 Set を割り当てることになる。
      value = yield(configured ? default | Array(configured).map(&:to_s) : default).freeze
      @masking_lists[key] = [configured, value]
      return value
    end

    # ⚠ **`(` を含む URL の `)` は URL の一部。** 一律に切ると
    # `https://en.wikipedia.org/wiki/Foo_(bar)` が壊れる。開き括弧が無いときだけ
    # 閉じ括弧を落とす。
    def split_trailing_punctuation(url)
      trailing = url[TRAILING_PUNCTUATION].to_s
      trailing = trailing.delete(')') if url.include?('(')
      return url, '' if trailing.empty?
      return url[0...-trailing.length], trailing
    end

    # ⚠⚠ **キーの大文字小文字で判定を変えない。** `Authorization` は HTTP
    # ヘッダの綴りそのもので、`:Token` / `"Password"` も普通に書かれる。完全一致
    # で見ていたため、**config に小文字で並べたキーの大文字違いが素通り**して
    # いた（`pooza/makoto2` の v0.4.0 リリース前レビューで実測。`:Token` /
    # `:TOKEN` / `:Authorization` / `"Password"` が平文で出た）。
    #
    # ⚠ **同じ file の中で非対称だった** — `mask_query_param?` は元から
    # `downcase` している。**片方だけ完全一致**は直し漏れとして読める。
    def mask_field?(key)
      return mask_fields.include?(key.to_s.downcase)
    end

    # ⚠ 設定は既定と**合成**する。**マスクしない方向へは倒さない**
    # （mask_query_params / mask_url_paths と同じ扱い）。
    def mask_fields
      return masking_list('/logger/mask_fields', MASK_FIELDS) {|v| v.to_set {|e| e.to_s.downcase}}
    end

    # URL に埋まった資格情報を落とす（クエリ・フラグメント／userinfo のパスワード／
    # 申告されたパスの接頭辞の次のセグメント）。
    #
    # mask_field? はキー名でしか判定できないため、`url: "...?access_token=xxx"`
    # のように**値の文字列の中に埋まった**トークンは素通りしていた。実際に
    # mulukhiya の listener がフルスコープのボットトークンを平文で syslog へ
    # 書き続けていた (pooza/mulukhiya-toot-proxy#4511)。HTTP#log も毎リクエスト
    # url: を出すので、局所対処ではなく Logger 側に置く。
    #
    # ⚠ 判定は URL のクエリに限ること。`i` は Misskey のトークンパラメータだが
    # 汎用名すぎるので、Hash のキーや素の文字列にまで広げると無関係な値まで
    # 落としてしまう。
    #
    # 🔴🔴 **URL をパースして組み直さない (#700)。** 以前は Addressable で読んでから
    # `query_values=` で書き戻していたが、
    # - **読めない URL は rescue で元の文字列をそのまま返していた**（`\` / `^` / `<>` / `"` /
    #   閉じていない `[`・zone id 付きの IPv6 は #609 で迂回を足した）
    # - 読めても `&amp;` / `sig[]=` / `;` 区切り / フラグメントは、名前として当たらなかった
    #
    # ⚠⚠ **区切りを文字列のまま見て、値の範囲だけを差し替える。** 読めないという状態が
    # 無くなり、**伏せないところは 1 バイトも変わらない**（正規化で URL が化けない）。
    #
    # ⚠ **引数まるごとを 1 つの URL とみなす (#712)。** 値やパスワードの中の空白でも切らない。
    # 文中の URL は `mask_urls_in` へ渡すこと。
    def mask_url(value)
      return mask_url_core(value, text: false)
    end

    # ⚠ `text:` は「URL の後ろに文が続くかもしれない」か（空白で切る）。
    def mask_url_core(value, text:, depth: 0)
      value = utf8_compatible(value.to_s)
      value = value.scrub('?') unless value.valid_encoding?
      return mask_escaped_url(value, text:, depth:) if shell_escaped?(value)
      return mask_plain_url(value, text:, depth:)
    end

    # ⚠ `Shellwords.escape` の形（`\X` と、改行の `'\n'`）を含むか。
    def shell_escaped?(value)
      return value.include?('\\') || value.include?("'\n'")
    end

    def mask_plain_url(value, text:, depth:)
      return value unless mask_url_candidate?(value)
      parts = (text ? URL_PARTS_PATTERN : URL_WHOLE_PARTS_PATTERN).match(value)
      path = masked_url_path(parts[:path]) || parts[:path]
      authority = masked_url_authority(parts[:authority])
      params = masked_url_params(parts[:rest], text:, depth:)
      return "#{parts[:scheme]}#{authority}#{path}#{params}"
    end

    # ⚠ HTTP#log は毎リクエスト url: を出す。どのルールにも当たりえない URL では
    # 何もしない。
    def mask_url_candidate?(value)
      return false unless value.match?(URL_PATTERN)
      return true if value.include?('?') || value.include?('#') || value.include?('@')
      return mask_url_prefixes(value).any?
    end

    # userinfo に埋まったパスワードを落とす (#589)。
    #
    # 🔴 **同じ URL のクエリは落ちるのに、隣にあるパスワードが平文で残っていた。**
    # `postgres://app:S3CRET@db/mydb` のような DSN は例外メッセージに載る
    # （`Sequel.connect` の失敗を `@logger.error(error: e)` で出す経路）。
    #
    # ⚠⚠ **ユーザ名は落とさない。** ユーザ名は診断に要るうえ、資格情報はパスワードの
    # ほう。⚠ `redis://:S3CRET@redis:6379/0` のように**ユーザ名が空**の形も拾う。
    # ⚠ userinfo は**最後の** `@` まで（パスワードに `@` があっても丸ごと落とす）。
    def masked_url_authority(authority)
      at = authority.rindex('@')
      return authority unless at
      colon = authority.index(':')
      return authority unless colon && colon < at - 1
      return "#{authority[..colon]}#{FILTERED}#{authority[at..]}"
    end

    # ⚠ 設定は既定と**合成**する。**マスクしない方向へは倒さない**
    # （config の不備で資格情報が平文に戻るほうが事故が大きい）。
    def mask_query_params
      return masking_list('/logger/mask_query_params', MASK_QUERY_PARAMS) do |v|
        v.to_set {|e| e.to_s.downcase}
      end
    end

    # ⚠ 設定は既定と**合成**する。**マスクしない方向へは倒さない** (#580)。
    # ⚠ 接頭辞の連続したスラッシュは 1 つに畳む（パスも畳んでから照合する。#712）。
    def mask_url_paths
      return masking_list('/logger/mask_url_paths', MASK_URL_PATHS) do |v|
        v.map {|e| e.to_s.squeeze('/')}.uniq
      end
    end

    # ⚠⚠ **利用側が「ログと同じマスク」を別経路にも掛けられるように公開する
    # (#580)。** 実例: Sentry の `before_send`。ログでは伏せている値が、例外
    # イベントとしてはそのまま外部サービスへ乗る
    # (pooza/tomato-shrieker#1467)。
    #
    # 🔴 **利用側で同等品を書かせないこと。** マスク対象の列が 2 か所に分かれ、
    # 必ずズレる。`/logger/mask_fields` と `/logger/mask_query_params` を
    # 唯一の正本に保つには、gem 側の実装をそのまま呼べる必要がある。

    # ⚠ 利用側が「ログと同じマスク」を別経路へ掛けられるように公開する。
    # 内部の判定ヘルパは private のまま。
    public :mask_url

    # ⚠⚠ **合成後の一覧そのものを要る利用側がある。**`mask` は当たったキーを
    # **落とす**ので、**「伏せたことを見せる」出力には使えない**。実例:
    # `pooza/makoto2` の `makoto config`（`Makoto::Config#secure_dump`）は
    # 資格情報を `(masked)` と表示する — 設定を点検する人に**キーが在ること
    # 自体は見せる**ための口で、消してしまうと点検にならない。
    #
    # 🔴 **公開しないと利用側が同等品を書く。** 実際に `makoto2` は
    # `/logger/mask_fields` だけを見ており、**#586 で広げた既定が届いていなかった**
    # （2026-08-31 の実測で **ログ 13 件に対し `makoto config` は 7 件**。
    # `apikey` / `client_secret` / `refresh_token` が抜けていた）。⚠ **設定に
    # その名前のキーを足した日に、ログでは伏せるのに CLI では平文**という形になる。
    #
    # ⚠ **`mask_url` を公開したのと同じ理由**（#580）。**マスク対象の列を 2 か所に
    # 分けない。**
    public :mask_fields

    # ⚠⚠ **「クエリのどの名前が資格情報か」は、マスクと同じ判断 (#653)。**
    # `Ginseng::HTTP::RedirectGuard` が「資格情報を持つ要求か」を決めるのに使う。
    # 🔴 一覧を 2 つ持つと、**片方だけ増えて穴になる** — 実際 `mask_fields` を
    # 公開したのも同じ理由（#625）。⚠ `masking_list` が凍らせた現物を返すので、
    # 受け取った側が `delete` してマスクを外すことはできない。
    public :mask_query_params
  end
end
