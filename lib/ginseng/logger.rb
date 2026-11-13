# frozen_string_literal: true

# ⚠⚠ **`Addressable::URI` はここで必ず読む。**
# 1.15.32（#493）で `FILTERED_ENCODED` を足したとき require を書き忘れており、
# **`uri.rb` が先に読まれていれば偶然動く**という読み込み順依存になっていた。
# ⚠ 実際に `pooza/cure-api` の常駐が
# `uninitialized constant Ginseng::Logger::Addressable` で起動しなくなった（2026-08-13）。
# ⚠ `Masking` は #700 で URL をパースしなくなった（`FILTERED_ENCODED` も外した）が、
# 読み込み順に頼っている箇所を洗い出していないので、require は外さない。
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

      # `/logger/level` が無いときの水準 (#755)。⚠ 従来どおり（`Syslog::Logger` の既定）。
      # 🔴 **`config/lib.yaml` には置かない** — 利用側では gem の `lib.yaml` が読まれない
      # （`Config#dirs` は利用側の `Environment.dir` を見る）ので、置いても届かず、
      # 利用側だけ別の既定になる（リリース前レビューの赤）。`MASK_FIELDS` と同じ理由。
      DEFAULT_LEVEL = 'DEBUG'

      # `/logger/level` が読めないときに倒す先 (#755)。
      FALLBACK_LEVEL = 'INFO'

      # 設定で受ける水準の名前 (#755)。⚠ `Logger::Severity.constants` から作らない —
      # 水準でない定数が増えると、それも通ってしまう。
      LEVELS = ['DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL', 'UNKNOWN'].freeze

      def initialize(name = nil)
        @config = config_class.instance
        name ||= package_class.name
        super
        value = configured_level
        self.level = ::Logger::Severity.const_get(level_name(value) || FALLBACK_LEVEL)
        return if level_name(value)
        # ⚠ **倒したことは残す**（`level: warning` の書き違いに気づけるように）。⚠ 値は短く切る。
        warn(message: 'logger level is invalid', value: value.to_s[0, 32], level: FALLBACK_LEVEL)
      end

      # `Syslog::Logger#add`（マスクを通さない）。⚠ **バックトレースの行のためだけに使う** (#759)。
      # ⚠⚠ **下の `def add` より前に置くこと** — 後ろに置くと上書きした `add` を指す。
      alias write_unmasked add
      private :write_unmasked

      # ⚠⚠ **マスクはここ 1 か所で通す (#759)。** `Syslog::Logger` の水準のメソッド
      # （`debug` / `info` / `warn` / `fatal` / `unknown`）はどれも `add` を呼ぶので、
      # ここを塞げば水準を問わず届く。
      #
      # 🔴 以前は水準のメソッドを 1 つずつ上書きして `create_entry` を通しており、
      # **上書きしていない `unknown` と、`add` を直に呼ぶ形が平文で出ていた**
      # （`logger.unknown(password: 'x')` が `{password: "x"}` のまま syslog へ。実測）。
      # ⚠ #755 で `/logger/level` に `unknown` を受けるようにしたので、選べる水準の口だけ
      # マスクが外れている形だった。⚠ 1 つずつ足す形は #499 の前にも、上書きしていなかった
      # debug / warn / fatal が平文で出ていた（info / error は #499 の残りでブロック形式を取りこぼした）。
      # ⚠ 水準は syslog の重要度として正当な使い分けなので、呼び出し側を info へ書き換えて回るのでは
      # なく、ここで塞ぐ（#478・pooza/mulukhiya-toot-proxy#4511 で warn に URL が出ていた）。
      #
      # ⚠ **ブロック形式 (`logger.warn {expensive}`) を殺さないこと。** 水準が無効なら
      # ブロックを評価しない（遅延の意味が失われる）。
      # ⚠ `progname` は標準の `::Logger` と同じく、本文もブロックも無いときだけ本文として扱う
      # （`add(sev, nil, 'message')` の形。捨てると本文が黙って消える）。⚠⚠ **`super` には渡さない** —
      # formatter を差し替えると、マスクを通していない `progname` がそのまま出る（実測）。
      def add(severity, message = nil, progname = nil)
        severity ||= ::Logger::UNKNOWN
        return true if severity < level
        message = block_given? ? yield : progname if message.nil?
        return super(severity, create_entry(message), nil)
      end

      # error はバックトレース展開があるので個別に定義している。1 行目は `add` を通す
      # （ブロック形式と水準の判定も `add` と同じ扱い）。
      #
      # ⚠⚠ **backtrace は nil になりうる。** raise していない例外を渡す呼び方
      # (`logger.error(StandardError.new('x'))`) があり、`create_message` 側は
      # #518 で塞いである（`test_create_message_accepts_unraised_error`）のに
      # ここだけ素で `each` を呼んでいて NoMethodError で**呼び出し側が落ちて
      # いた**。⚠ ログを出そうとした側が落ちる型は #518 で踏んだのと同じ。
      #
      # ⚠ バックトレースの行は JSON にしない（従来どおり 1 行ずつ素の文字列）ので、
      # `add` を通さず `write_unmasked` で書く。⚠ 中身は普通はファイル・行番号・メソッド名だが、
      # `eval` のファイル名や `set_backtrace` で任意の文字列が入るので、URL のマスクだけは通す（実測で
      # `access_token=` が平文で出た。7.0.0 から）。
      def error(message = nil)
        return true unless error?
        message = yield if message.nil? && block_given?
        add(::Logger::ERROR, message)
        return unless message.is_a?(StandardError)
        message.backtrace&.each do |entry|
          write_unmasked(::Logger::ERROR, "  #{mask_urls_in(scrub(entry))}")
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

      # 設定の `/logger/level` (#755)。⚠⚠ **読めなくても例外を上げない。** ログの出口が設定の
      # 不備で落ちると、その例外を書く先も無い。
      def configured_level
        return @config['/logger/level']
      rescue ConfigError
        return nil
      end

      # 受ける水準の名前。読めない値なら nil（→ info。⚠ **黙る方向（error など）へは倒さない**）。
      # ⚠ 無ければ（未設定・`nil`）従来どおり debug。
      def level_name(value)
        return DEFAULT_LEVEL if value.nil?
        name = value.to_s.upcase
        return name if LEVELS.include?(name)
        return nil
      end

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
