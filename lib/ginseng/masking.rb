# frozen_string_literal: true

require 'addressable/uri'

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
    FILTERED = '[FILTERED]'
    # query_values= が値に使う encode 規則。encode_component の既定の
    # charclass では角括弧が残ってしまい、実際の出力と一致しない。
    FILTERED_ENCODED = Addressable::URI.encode_component(
      FILTERED,
      Addressable::URI::CharacterClasses::UNRESERVED,
    ).freeze

    # Hash のキーに現れたら値ごと落とす資格情報の既定値。
    # config の `/logger/mask_fields` で上書きできる。
    #
    # ⚠ **既定を空にしないこと。** 設定を書き忘れたアプリが守られる状態を既定に
    # する（mask_query_params と同じ判断）。
    MASK_FIELDS = [
      'password',
      'secret',
      'token',
    ].freeze

    # URL のクエリに現れたら落とす資格情報パラメータの既定値。
    # config の `/logger/mask_query_params` で上書きできる。
    MASK_QUERY_PARAMS = [
      'access_token',
      'api_key',
      'apikey',
      'client_secret',
      'code',
      'i',
      'key',
      'password',
      'refresh_token',
      'secret',
      'token',
    ].freeze

    # URL の**パス**に現れたら次の 1 セグメントを落とす接頭辞の既定値。
    # config の `/logger/mask_url_paths` で上書きできる (#580)。
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

    # userinfo にパスワードを持つ URL (#589)。⚠ `://` から最初の `/` までの間に
    # `:` と `@` が並ぶ形だけを見る。`https://user@example.com`（パスワード無し）と
    # `http://example.com:8080/`（ポート）を巻き込まないため。
    URL_USERINFO_PATTERN = %r{\A[a-z][a-z0-9+.-]*://[^/?\#@]*:[^/?\#@]*@}i

    # 文字列の**途中**に埋まった URL を拾う (#582)。⚠ URL_PATTERN と違って錨が
    # 無い。アプリは `"Invalid feed #{id} (#{uri}) ..."` のように例外メッセージへ
    # URL を埋めるので、そこを拾えないと資格情報が素通りする。
    URL_IN_TEXT_PATTERN = %r{[a-z][a-z0-9+.-]*://[^\s<>"'`\\^{}|\[\]]+}i

    # URL の末尾に付きがちで、URL 本体ではないことが多い文字。
    TRAILING_PUNCTUATION = /[).,;:!?]+\z/

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
      # ⚠⚠ **ASCII 非互換なエンコーディングは `include?` の時点で落ちる (#591)。**
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
      # ⚠ HTTP#log は毎リクエスト通る。当たらない文字列で走査しない。
      return text unless text.include?('://')
      # ⚠⚠ **不正なバイト列は gsub の時点で ArgumentError を上げる (#518 / #587)。**
      # ここで落とすと利用側が rescue を書くことになり、**マスクの正本を 1 か所に
      # 保つ**という #580 の前提が崩れる（pooza/tomato-shrieker に実際に rescue が
      # 生えていた）。
      #
      # 🔴 **mask_url のように「rescue して元の文字列を返す」にしないこと。**
      # それだと URL の資格情報が平文で残る（v1.20.0 が実際にそうだった）。
      # **scrub してからマスクする** — ログ経路（create_entry）と同じ倒し方。
      text = text.scrub('?') unless text.valid_encoding?
      return text.gsub(URL_IN_TEXT_PATTERN) do |url|
        core, trailing = split_trailing_punctuation(url)
        "#{mask_url(core)}#{trailing}"
      end
    end

    private

    # 設定のリストを引く。設定が無ければ既定へ倒す。**マスクしない方向へは倒さない。**
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
      source = configured || default
      @masking_lists ||= {}
      cached = @masking_lists[key]
      return cached.last if cached && cached.first == source
      value = yield(source)
      @masking_lists[key] = [source, value]
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

    # 設定が無い場合は既定のリストへ倒す。**マスクしない方向へは倒さない**
    # （mask_query_params / mask_url_paths と同じ扱い）。
    def mask_fields
      return masking_list('/logger/mask_fields', MASK_FIELDS) {|v| v.to_set {|e| e.to_s.downcase}}
    end

    # URL のクエリに埋まった資格情報を落とす
    # (pooza/mulukhiya-toot-proxy#4511)。
    #
    # mask_field? はキー名でしか判定できないため、`url: "...?access_token=xxx"`
    # のように**値の文字列の中に埋まった**トークンは素通りしていた。実際に
    # mulukhiya の listener がフルスコープのボットトークンを平文で syslog へ
    # 書き続けていた。HTTP#log も毎リクエスト url: を出すので、局所対処では
    # なく Logger 側に置く。
    #
    # ⚠ 判定は URL のクエリに限ること。`i` は Misskey のトークンパラメータだが
    # 汎用名すぎるので、Hash のキーや素の文字列にまで広げると無関係な値まで
    # 落としてしまう。
    def mask_url(value)
      return value unless mask_url_candidate?(value)
      uri = Addressable::URI.parse(value)
      # ⚠ **どれか一つでも当たれば書き出す。** 当たらなければ元の文字列を
      # そのまま返す。正規化で URL が化ける後退を入れないため。
      path = masked_url_path(uri)
      query = masked_url_query(uri)
      password = masked_url_password(uri)
      return value unless path || query || password
      uri.path = path if path
      uri.query_values = query if query
      uri.password = password if password
      # path= / query_values= は値を percent-encode するので、目印の角括弧が
      # `%5BFILTERED%5D` になってログが読みにくい。自分で入れた目印だけ戻す。
      return uri.to_s.gsub(FILTERED_ENCODED, FILTERED)
    # ⚠⚠ **不正なバイト列は正規表現の時点で ArgumentError を上げる (#518)。**
    # ここで受けないと create_message の rescue まで飛び、**mask ごと素通りして
    # mask_fields のキーまで平文で出る**。⚠ ログ経路は create_entry が先に scrub
    # するのでここへは来ないが、create_message を直接呼ぶ利用側のために塞ぐ。
    rescue Addressable::URI::InvalidURIError, ArgumentError, Encoding::CompatibilityError
      return value
    end

    # parse する前の足切り。⚠ **HTTP#log は毎リクエスト url: を出す**ので、
    # どのルールにも当たらない URL で Addressable のパースを走らせない。
    def mask_url_candidate?(value)
      return false unless value.match?(URL_PATTERN)
      return true if value.include?('?')
      # ⚠ `@` を含む URL は珍しいので、`include?` で足切りしてから正規表現へ (#589)。
      return true if value.include?('@') && value.match?(URL_USERINFO_PATTERN)
      return !mask_url_prefix(value).nil?
    end

    def mask_url_prefix(value)
      return mask_url_paths.find {|v| value.include?(v)}
    end

    # パスに埋まった資格情報を落としたパスを返す。落とすものが無ければ nil (#580)。
    #
    # 🔴 **モロヘイヤの webhook は digest を知っていれば誰でも投稿できる。**
    # tomato-shrieker の本番では、成功した POST のたびに
    # `{"method":"POST","url":"https://.../mulukhiya/webhook/<digest>","status":200}`
    # が平文で syslog に出ていた（2026-08-25 の当日ログで 22 行）。
    #
    # ⚠ **伏せるのは接頭辞の次の 1 セグメントだけ。** 以降のパスは残す。
    def masked_url_path(uri)
      path = uri.path
      return nil unless (prefix = mask_url_prefix(path))
      head, _, rest = path.partition(prefix)
      return nil if rest.empty?
      secret, slash, tail = rest.partition('/')
      return nil if secret.empty?
      return "#{head}#{prefix}#{FILTERED}#{slash}#{tail}"
    end

    # userinfo に埋まったパスワードを落とす。無ければ nil (#589)。
    #
    # 🔴 **同じ URL のクエリは落ちるのに、隣にあるパスワードが平文で残っていた。**
    # `postgres://app:S3CRET@db/mydb` のような DSN は例外メッセージに載る
    # （`Sequel.connect` の失敗を `@logger.error(error: e)` で出す経路）。
    #
    # ⚠⚠ **ユーザ名は落とさない。** ユーザ名は診断に要るうえ、資格情報はパスワードの
    # ほう。⚠ `redis://:S3CRET@redis:6379/0` のように**ユーザ名が空**の形も拾う。
    def masked_url_password(uri)
      return nil if uri.password.blank?
      return FILTERED
    end

    # クエリに埋まった資格情報を落とした query 配列を返す。無ければ nil。
    def masked_url_query(uri)
      query = uri.query_values(Array)
      return nil if query.blank?
      return nil unless query.any? {|k, _| mask_query_param?(k)}
      return query.map {|k, v| [k, mask_query_param?(k) ? FILTERED : v]}
    end

    def mask_query_param?(key)
      return mask_query_params.include?(key.to_s.downcase)
    end

    # 設定が無い場合は既定のリストへ倒す。**マスクしない方向へは倒さない**
    # （config の不備で資格情報が平文に戻るほうが事故が大きい）。
    def mask_query_params
      return masking_list('/logger/mask_query_params', MASK_QUERY_PARAMS) do |v|
        v.to_set {|e| e.to_s.downcase}
      end
    end

    # 設定が無い場合は既定のリストへ倒す。**マスクしない方向へは倒さない** (#580)。
    def mask_url_paths
      return masking_list('/logger/mask_url_paths', MASK_URL_PATHS) {|v| v.map(&:to_s)}
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
  end
end
