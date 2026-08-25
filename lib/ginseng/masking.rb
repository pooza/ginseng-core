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
      # ⚠ HTTP#log は毎リクエスト通る。当たらない文字列で走査しない。
      return text unless text.include?('://')
      return text.gsub(URL_IN_TEXT_PATTERN) do |url|
        core, trailing = split_trailing_punctuation(url)
        "#{mask_url(core)}#{trailing}"
      end
    end

    private

    # ⚠ **`(` を含む URL の `)` は URL の一部。** 一律に切ると
    # `https://en.wikipedia.org/wiki/Foo_(bar)` が壊れる。開き括弧が無いときだけ
    # 閉じ括弧を落とす。
    def split_trailing_punctuation(url)
      trailing = url[TRAILING_PUNCTUATION].to_s
      trailing = trailing.delete(')') if url.include?('(')
      return url, '' if trailing.empty?
      return url[0...-trailing.length], trailing
    end

    def mask_field?(key)
      return @config['/logger/mask_fields'].include?(key.to_s)
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
      # ⚠ **どちらか一方でも当たれば書き出す。** 当たらなければ元の文字列を
      # そのまま返す。正規化で URL が化ける後退を入れないため。
      path = masked_url_path(uri)
      query = masked_url_query(uri)
      return value unless path || query
      uri.path = path if path
      uri.query_values = query if query
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
      @mask_query_params ||= begin
        configured = begin
          @config['/logger/mask_query_params']
        rescue ConfigError
          nil
        end
        (configured || MASK_QUERY_PARAMS).to_set {|v| v.to_s.downcase}
      end
    end

    # 設定が無い場合は既定のリストへ倒す。**マスクしない方向へは倒さない** (#580)。
    def mask_url_paths
      @mask_url_paths ||= begin
        configured = begin
          @config['/logger/mask_url_paths']
        rescue ConfigError
          nil
        end
        (configured || MASK_URL_PATHS).map(&:to_s)
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
  end
end
