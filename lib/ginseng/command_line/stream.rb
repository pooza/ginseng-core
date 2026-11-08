# frozen_string_literal: true

module Ginseng
  class CommandLine
    # 実行しながら出力を流す `exec(io:)` (#745)。
    #
    # ⚠⚠ この口が無かった頃、利用側は `exec` を丸ごと写していた（pooza/chubo-core の
    # `StreamCommandLine`）。写しには、その後の直し（締切で子を止める #684・`user=`・
    # `spawn_env` #480 / #710）が届かない。
    #
    # - **1 行ずつ流す。** 改行を待つので、`\r` で書き直す進捗表示（curl など）は、
    #   改行が来るまで出ない。⚠ stdout と stderr の行は混ざるが、1 行の途中で混ざることは無い
    # - ⚠ **`stdout` / `stderr` は従来どおり全部を持つ**（伏せない。流さないときと同じ値）
    # - ⚠ **流す行で伏せるのは `secrets=` の値だけ。** 🔴 `log_exec` の行と違い、URL の資格情報
    #   （userinfo・`?token=`）や `Authorization:` の行は伏せない（6.1.0 のリリース前レビューで実測）。
    #   流し先は端末やログになるので、出力に資格情報が載るコマンドでは `secrets=` に渡すこと。
    #   ⚠ 行をまたぐ秘密も伏せられない
    # - ⚠ **流し先が詰まると、子も詰まる**（読む手が止まり、パイプが埋まる）。締切は効く。
    #   ⚠ 締切で止めたとき、読み手が流し先で詰まっていると、コマンドが終わっていても
    #   「止められなかった（`still running`）」と出る — 読み手の生死で判定しているため
    # - ⚠ **流し先が壊れても、コマンドは止めない。** 書けなくなった時点で流すのをやめ、
    #   warn を 1 行残す。出力は最後まで読む（`stdout` / `stderr` は欠けない）
    module Stream
      # 流し先。2 本の読み手から書かれるので、1 行ずつ排他で書く。
      #
      # 🔴 **流し先の例外は種類を問わず受ける (#746 Codex P2)。** `IOError` / `SystemCallError` だけを
      # 受けていたので、流し先が書けない文字（`w:US-ASCII` のファイルに `あ`）で上がる
      # `Encoding::UndefinedConversionError` が読み手を落とし、`exec` が例外になって `stdout` も
      # 欠けた。⚠ 利用側が渡す流し先は任意のオブジェクトなので、何が上がるかはこちらで列挙できない。
      # ⚠ 知らせる側（warn を出す logger）の例外も受ける。落ちると同じく `exec` が例外になる
      # （6.1.0 のリリース前レビューで実測。logger を差し替える利用側で起こりうる）。
      class Sink
        # 子の pid。warn の行に出す（並行して走る利用側で、どの実行か分かるように）。
        attr_accessor :pid

        def initialize(io, &on_failure)
          @io = io
          @lock = Mutex.new
          @on_failure = on_failure
          @live = true
        end

        def live?
          return @live
        end

        def write(line)
          @lock.synchronize do
            return unless @live
            @io.write(line)
          rescue => e
            @live = false
            notify(e)
          end
        end

        private

        def notify(error)
          @on_failure&.call(error, pid)
        rescue
          nil
        end
      end

      private_constant :Sink

      private

      # ⚠ **受け取る側で検査する。** `write` を持たない値（`true` など）を黙って受けると、
      # 読み手のスレッドが `NoMethodError` で落ちて、それが `exec` の例外になる。
      def stream_sink(io)
        return nil if io.nil?
        raise ArgumentError, "io must respond to #write (#{io.class})" unless io.respond_to?(:write)
        return Sink.new(io) {|error, pid| log_stream_failure(error, pid)}
      end

      # 締切の無い経路で、出力を流しながら受け取る。⚠ `Open3.capture3` と同じく、標準入力は空。
      # ⚠⚠ **両方のパイプを同時に読む。** 片方を読み切ってからもう片方を読むと、後のほうの
      # パイプが埋まった時点で子が書けずに止まり、こちらは前のほうの EOF を待ち続ける。
      # ⚠ **中断されたら読み手を止める**（6.1.0 のリリース前レビュー）。流し先で詰まった読み手は、
      # パイプを閉じても戻らず残っていた。締切の経路（`Deadline#release`）と同じ後始末。
      # ⚠ 子の終了を待つのは `Open3.popen3` の後始末で、`capture3` と同じ（中断しても子が終わるまで戻らない）。
      def capture_streaming(sink)
        Open3.popen3(*spawn_args, **spawn_options) do |stdin, out, err, waiter|
          stdin.close
          sink.pid = waiter.pid
          readers = [out, err].map {|io| Thread.new {drain(io, sink)}}
          begin
            @stdout, @stderr = readers.map(&:value)
          ensure
            readers.each {|reader| reader.kill if reader.alive?}
          end
          @status = waiter.value
        end
      end

      # パイプを読み切って全体を返す。`sink` があれば、読んだ行を伏せて流す。
      # ⚠ 全体はパイプの符号化のまま（`IO#read` と同じ）。不正なバイト列も、そのまま持つ。
      # ⚠ 流し先が壊れたら、残りは伏せずにまとめて読む（伏せる手間を流さない行に払わない）。
      def drain(io, sink)
        return io.read unless sink
        buffer = String.new(encoding: io.external_encoding || Encoding.default_external)
        patterns = nil
        io.each_line do |line|
          buffer << line
          patterns ||= stream_mask_patterns(line.encoding)
          sink.write(mask_line(line, patterns))
          break buffer << io.read.to_s unless sink.live?
        end
        return buffer
      end

      # 流す行で伏せる形（パイプ 1 本につき 1 回だけ作る）。
      #
      # 🔴 **行ごとに `masked` を呼ぶと遅い（6.1.0 のリリース前レビュー）。** `masked` は呼ぶたびに
      # 秘密ごとの `shellescape` を作り直すので、秘密 3 つ・50 万行で 14 秒かかり、締切つきでは
      # **流さなければ 0.04 秒で終わるコマンドが締切で止められた**（読む手が遅れてパイプが埋まる）。
      # ⚠ 順番は `masked` と同じ（長い秘密から、生の形 → エスケープした形）。
      def stream_mask_patterns(encoding)
        return secrets.flat_map {|secret| mask_patterns(secret, encoding)}
      end

      # ⚠ 文字列で当てる（`gsub` を正規表現にすると、不正なバイト列の行で `ArgumentError` になる）。
      # ⚠ 置換はブロック形式（置換文字列の `\\1` が後方参照として食われないように）。
      def mask_line(line, patterns)
        return patterns.inject(line) do |masked_line, pattern|
          next masked_line unless masked_line.include?(pattern)
          masked_line.gsub(pattern) {Masking::FILTERED}
        end
      end

      # ⚠ 例外の文言はパスなどを含みうるので、`masked` を通す。
      def log_stream_failure(error, pid)
        @logger.warn(
          command: masked_to_s, pid:, error: error.class.name, message: masked(error.message),
          detail: 'stopped streaming the output; the command keeps running'
        )
      end
    end
  end
end
