# frozen_string_literal: true

# ⚠⚠ **`Addressable::URI` を下でクラス定義時に使うので、ここで必ず読む。**
# 1.15.32（#493）で `FILTERED_ENCODED` を足したとき require を書き忘れており、
# **`uri.rb` が先に読まれていれば偶然動く**という読み込み順依存になっていた。
# ⚠ 実際に `pooza/cure-api` の常駐が
# `uninitialized constant Ginseng::Logger::Addressable` で起動しなくなった（2026-08-13）。
require 'addressable/uri'

module Ginseng
  if Environment.win?
    class Logger
      def info(message)
      end

      def error(message)
      end

      def debug(message)
      end

      def warn(message)
      end

      def fatal(message)
      end
    end
  else
    require 'syslog/logger'
    class Logger < Syslog::Logger
      include Package

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

      URL_PATTERN = %r{\A[a-z][a-z0-9+.-]*://}i

      # 不正なバイト列を落として出したことの印 (#518)。
      ENCODING_ERROR_FIELD = :_encoding_error

      # ⚠ マスクを通せなかったので中身を出さなかったことの印 (#529)。
      MASK_ERROR_FIELD = :_mask_error

      def initialize(name = nil)
        @config = config_class.instance
        name ||= package_class.name
        super
      end

      def info(message)
        super(create_entry(message))
      end

      def error(message)
        super(create_entry(message))
        return unless message.is_a?(StandardError)
        message.backtrace.each do |entry|
          super("  #{scrub(entry)}")
        end
      end

      # ⚠ **info / error 以外の severity も create_message を通すこと** (#499)。
      # ここを空けておくと、`warn` を使った瞬間に出力が Hash#to_s へ戻り、
      # mask / mask_url（#478、pooza/mulukhiya-toot-proxy#4511）が丸ごと効かなく
      # なる。severity は syslog の重要度として正当な使い分けなので、呼び出し側を
      # info へ書き換えて回るのではなくここで塞ぐ。
      # error はバックトレース展開があるので上で個別に定義している。
      #
      # ⚠ **ブロック形式 (`logger.warn {expensive}`) を殺さないこと。**Syslog::Logger
      # の severity メソッドは message 省略 + ブロックを受けるので、必須引数にすると
      # 既存の呼び出しが ArgumentError になる。severity が無効なときはブロックを
      # 評価しない（遅延の意味が失われる）。
      [:debug, :warn, :fatal].each do |severity|
        define_method(severity) do |message = nil, &block|
          return true unless send(:"#{severity}?")
          message = block.call if message.nil? && block
          super(create_entry(message))
        end
      end

      # syslog へ渡す 1 行を組み立てる。**必ず妥当な UTF-8 を返し、例外を上げない**
      # (#518)。
      #
      # ⚠⚠ **不正なバイト列の壊れ方は環境で 2 通りある。両方を塞ぐ。**
      #
      # 1. **例外**: 素の json gem の generator では `JSON::GeneratorError` が上がる。
      #    `create_message` には rescue があるのに `to_json` はその外にあったので、
      #    **ログを出そうとした側が落ちて 1 行丸ごと消えていた**（依頼元の
      #    mulukhiya-toot-proxy で発生。リクエストログが残らないだけでなく、
      #    rescue が走って本来と違う 401 でクライアントへ返っていた）
      # 2. ⚠ **素通し**: この gem は `yajl/json_gem` を読むので、**Yajl は例外を
      #    上げず不正なバイト列をそのまま出す**。⚠⚠ **syslog に妥当でない UTF-8 の
      #    行が残り、ログを JSON として読む側がそこで落ちる**（実測で確認した）
      #
      # ⚠ ログは最後の観測手段なので、**壊れたバイト列を落としてでも 1 行出す**。
      # 投稿本文と違い、化けた表示より無音のほうが害が大きい。⚠ 直したことが
      # 分かるよう `_encoding_error: true` を添える。黙って直すが、黙って直した
      # ことは隠さない。
      #
      # 🔴 **判定は mask より前に行うこと。** 不正なバイト列を含む文字列を
      # `mask_url` の正規表現にかけると ArgumentError が上がり、
      # **`create_message` の rescue が素の src を返す ＝ マスクが丸ごと外れる**。
      # ⚠⚠ 実測では `password:` と URL の `access_token=` が**平文のまま**出た。
      def create_entry(src)
        return create_scrubbed_entry(src) if broken?(src)
        entry = create_message(src).to_json
        return entry if entry.valid_encoding?
        return create_scrubbed_entry(src)
      rescue JSON::GeneratorError, EncodingError
        return create_scrubbed_entry(src)
      end

      # ⚠⚠ **どの形で渡されても mask を通すこと (#529)。**
      #
      # 以前は `Hash` と `{error:}` と `StandardError` しか受けず、**それ以外は
      # `NoMatchingPatternError` → 下の `rescue` で素通し**していた。⚠ 実測では
      # 3 つの経路が平文で出ていた。
      #
      # ```
      # logger.info('https://example.com/?access_token=SECRET')   # トップレベルの文字列
      # logger.info(['https://example.com/?token=SECRET'])        # トップレベルの配列
      # logger.info(error: 'https://...?token=SECRET', password: 'hoge')  # error: が例外でない
      # ```
      #
      # ⚠ **`logger.info(url)` は最も自然な呼び方**なので、経路としては太い。
      def create_message(src)
        case src
        # ⚠ **型を見ること。** `error:` に例外以外が入る呼び方があり
        # (`logger.info(error: 'message')`)、型を見ずに backtrace を呼ぶと
        # NoMethodError → rescue → **その行のマスクが丸ごと外れる**。
        in {error: StandardError => error}
          file, line = error.backtrace&.first.to_s.split(':')
          return mask(src.merge(error: {
            message: error.message,
            file: file.to_s.sub("#{Environment.dir}/", ''),
            line: line.to_i,
          }))
        in StandardError
          # ⚠ **message に URL が埋まっていることがある**ので mask を通す。
          return mask(src.to_h)
        else
          # Hash / Array / String / それ以外を全部ここで受ける。mask は型ごとに
          # 分岐するので、ここで型を絞る必要は無い。
          return mask(src)
        end
      rescue
        # ⚠⚠ **fail closed (#529)。** ここへ来た時点で mask を通せていないので、
        # 素の src を返すと資格情報が平文で出る（#518 で実際に踏んだ型）。
        # ⚠ キー名は mask が元から残す側なので、手掛かりとして添える。
        entry = {MASK_ERROR_FIELD => true, class: src.class.to_s}
        entry[:keys] = src.keys.map(&:to_s) if src.is_a?(Hash)
        return entry
      end

      private

      # ⚠⚠ **scrub してから create_message をやり直す。** mask を通し直さないと
      # マスクが外れたままになる（上記）。
      def create_scrubbed_entry(src)
        message = scrub(create_message(scrub(src)))
        message = {message:} unless message.is_a?(Hash)
        entry = message.merge(ENCODING_ERROR_FIELD => true).to_json
        return entry if entry.valid_encoding?
        return {ENCODING_ERROR_FIELD => true}.to_json
      rescue JSON::GeneratorError, EncodingError
        # ⚠ ここまで来たら中身は諦める。**行が消えたことだけは残す**
        # （無音だと、そもそも出そうとしたことすら追えない）。
        return {ENCODING_ERROR_FIELD => true}.to_json
      end

      # JSON にできないバイト列を含むか。⚠ **判定だけで複製を作らない**
      # （毎行通るので、壊れていない側にコストを乗せない）。
      def broken?(value)
        case value
        in Hash
          return value.any? {|k, v| broken?(k) || broken?(v)}
        in Array
          return value.any? {|v| broken?(v)}
        in String
          return true unless value.valid_encoding?
          # ⚠ ASCII-8BIT は「妥当」だが、非 ASCII を含むと JSON にできない。
          return value.encoding == Encoding::BINARY && !value.ascii_only?
        else
          return false
        end
      end

      # 不正なバイト列を `?` へ落とした複製を返す。
      #
      # ⚠ **UTF-8 以外の妥当な文字列は壊さないこと。**Shift_JIS のような正しい
      # 文字列まで `?` にすると、読めたはずのログが読めなくなる。
      def scrub(value)
        case value
        in Hash
          return value.to_h {|k, v| [scrub(k), scrub(v)]}
        in Array
          return value.map {|v| scrub(v)}
        in Symbol
          return scrub(value.to_s).to_sym
        in String
          return value.scrub('?') if value.encoding == Encoding::UTF_8
          return value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
        else
          return value
        end
      rescue EncodingError
        return value.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?')
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
          return mask_url(arg)
        else
          return arg
        end
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
        return value unless value.include?('?')
        return value unless value.match?(URL_PATTERN)
        uri = Addressable::URI.parse(value)
        query = uri.query_values(Array)
        return value if query.blank?
        return value unless query.any? {|k, _| mask_query_param?(k)}
        uri.query_values = query.map {|k, v| [k, mask_query_param?(k) ? FILTERED : v]}
        # query_values= は値を percent-encode するので、目印の角括弧が
        # `%5BFILTERED%5D` になってログが読みにくい。自分で入れた目印だけ戻す。
        return uri.to_s.gsub(FILTERED_ENCODED, FILTERED)
      # ⚠⚠ **不正なバイト列は正規表現の時点で ArgumentError を上げる (#518)。**
      # ここで受けないと create_message の rescue まで飛び、**mask ごと素通りして
      # mask_fields のキーまで平文で出る**。⚠ ログ経路は create_entry が先に scrub
      # するのでここへは来ないが、create_message を直接呼ぶ利用側のために塞ぐ。
      rescue Addressable::URI::InvalidURIError, ArgumentError, Encoding::CompatibilityError
        return value
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
    end
  end
end
