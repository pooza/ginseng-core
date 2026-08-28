# frozen_string_literal: true

module Ginseng
  # Windows 版のロガー。syslog が無いので記録しない。
  #
  # ⚠⚠ **`Environment.win?` の外に、独立したファイルとして置く (#602 / #604)。**
  # `logger.rb` の分岐の内側に書くと、**CI（`ubuntu-latest` だけ）ではこのクラスが
  # 1 行も検査できない**。実際そうなっていて、Windows のスタブだけ壊れていても
  # 緑のままだった。⚠ ここに置けば、どの環境でも実物を直に叩くテストが書ける。
  #
  # 🔴 **Zeitwerk があるので、ファイルを分けること自体が必須。** `logger.rb` が
  # 定義してよいのは `Ginseng::Logger` だけで、そこに `WindowsLogger` を書いても
  # **`Ginseng::Logger` を先に触ったときしか定義されない**（実測で NameError を
  # 踏んだ）。
  class WindowsLogger
    include Package

    # ⚠⚠ **マスクの API は Windows にも生やす (#602)。** `mask` / `mask_url` /
    # `mask_urls_in` は **public として配っている** API で、Sentry の
    # `before_send` から呼ばれる (pooza/tomato-shrieker#1467)。ここに無いと
    # **Windows でだけ NoMethodError** になり、利用側から見ると「あるはずの
    # API が無い」形になる。⚠ 実装は Masking に寄せてあるので、プラット
    # フォームに依存する部分は無い。
    include Masking

    # ⚠ **実装側と同じシグネチャにしておく**（下の severity と同じ理由）。
    # 無いと `Logger.new(name)` が Windows でだけ ArgumentError になる。
    # ⚠⚠ **Masking は include する側が `@config` を持つことを要求している**
    # (masking.rb の冒頭)。持たせないと mask_fields などが落ちる。
    def initialize(_name = nil)
      @config = config_class.instance
    end

    # ⚠ 実装側と同じシグネチャにしておく。必須引数のままだと
    # `logger.info {expensive}` が Windows でだけ ArgumentError になる。
    def info(message = nil)
    end

    def error(message = nil)
    end

    def debug(message = nil)
    end

    def warn(message = nil)
    end

    def fatal(message = nil)
    end
  end
end
