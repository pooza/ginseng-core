# frozen_string_literal: true

# ⚠⚠ **`Addressable::URI` を下でクラス定義時に使うので、ここで必ず読む。**
# 1.15.32（#493）で `FILTERED_ENCODED` を足したとき require を書き忘れており、
# **`uri.rb` が先に読まれていれば偶然動く**という読み込み順依存になっていた。
# ⚠ 実際に `pooza/cure-api` の常駐が
# `uninitialized constant Ginseng::Logger::Addressable` で起動しなくなった（2026-08-13）。
require 'addressable/uri'

module Ginseng
  # ⚠⚠ **Windows 版は [WindowsLogger](windows_logger.rb)（別ファイル）。**
  # ここに直接書くと Zeitwerk が拾えず（`logger.rb` が定義してよいのは
  # `Ginseng::Logger` だけ）、**`Ginseng::Logger` を先に触ったときしか
  # `Ginseng::WindowsLogger` が定義されない**（#604 で実測。NameError を踏んだ）。
  # ⚠ 分けたことで、Linux の CI でも Windows 版を直に検査できる。
  if Environment.win?
    Logger = WindowsLogger
  else
    require 'syslog/logger'
    class Logger < Syslog::Logger
      include Package

      include Masking

      # 不正なバイト列を落として出したことの印 (#518)。
      ENCODING_ERROR_FIELD = :_encoding_error

      # ⚠ マスクを通せなかったので中身を出さなかったことの印 (#529)。
      MASK_ERROR_FIELD = :_mask_error

      def initialize(name = nil)
        @config = config_class.instance
        name ||= package_class.name
        super
      end

      # error はバックトレース展開があるので個別に定義している。ブロック形式と
      # severity の判定は下のループと同じ扱いにする。
      #
      # ⚠⚠ **backtrace は nil になりうる。** raise していない例外を渡す呼び方
      # (`logger.error(StandardError.new('x'))`) があり、`create_message` 側は
      # #518 で塞いである（`test_create_message_accepts_unraised_error`）のに
      # ここだけ素で `each` を呼んでいて NoMethodError で**呼び出し側が落ちて
      # いた**。⚠ ログを出そうとした側が落ちる型は #518 で踏んだのと同じ。
      def error(message = nil)
        return true unless error?
        message = yield if message.nil? && block_given?
        super(create_entry(message))
        return unless message.is_a?(StandardError)
        message.backtrace&.each do |entry|
          super("  #{scrub(entry)}")
        end
      end

      # ⚠ **すべての severity を create_message に通すこと** (#499)。
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
      #
      # ⚠⚠ **info もここに入れる。**#499 で 3 つだけ直したときに info / error が
      # 残っており、**いちばん使われる 2 つでブロック形式が ArgumentError のまま**
      # だった（`pooza/makoto2#107` の実機確認で発覚）。
      [:debug, :info, :warn, :fatal].each do |severity|
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
    end
  end
end
