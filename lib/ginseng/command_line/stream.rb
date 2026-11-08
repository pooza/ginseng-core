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
    # - 🔴 **流す行は `secrets=` の値を伏せる。** 流し先は端末やログで、`log_exec` の行と同じ
    #   扱いになるため。⚠ 行をまたぐ秘密は伏せられない
    # - ⚠ **流し先が詰まると、子も詰まる**（読む手が止まり、パイプが埋まる）。締切は効く
    # - 🔴 **流し先が壊れても、コマンドは止めない。** 書けなくなった時点で流すのをやめ、
    #   warn を 1 行残す。出力は最後まで読む（`stdout` / `stderr` は欠けない）
    module Stream
      # 流し先。2 本の読み手から書かれるので、1 行ずつ排他で書く。
      class Sink
        def initialize(io, &on_failure)
          @io = io
          @lock = Mutex.new
          @on_failure = on_failure
          @live = true
        end

        def write(line)
          @lock.synchronize do
            return unless @live
            @io.write(line)
          rescue IOError, SystemCallError => e
            @live = false
            @on_failure&.call(e)
          end
        end
      end

      private_constant :Sink

      private

      # ⚠ **受け取る側で検査する。** `write` を持たない値（`true` など）を黙って受けると、
      # 読み手のスレッドが `NoMethodError` で落ちて、それが `exec` の例外になる。
      def stream_sink(io)
        return nil if io.nil?
        raise ArgumentError, "io must respond to #write (#{io.class})" unless io.respond_to?(:write)
        return Sink.new(io) {|error| log_stream_failure(error)}
      end

      # 締切の無い経路で、出力を流しながら受け取る。⚠ `Open3.capture3` と同じく、標準入力は空。
      # ⚠⚠ **両方のパイプを同時に読む。** 片方を読み切ってからもう片方を読むと、後のほうの
      # パイプが埋まった時点で子が書けずに止まり、こちらは前のほうの EOF を待ち続ける。
      def capture_streaming(sink)
        Open3.popen3(*spawn_args, **spawn_options) do |stdin, out, err, waiter|
          stdin.close
          readers = [out, err].map {|io| Thread.new {drain(io, sink)}}
          @stdout, @stderr = readers.map(&:value)
          @status = waiter.value
        end
      end

      # パイプを読み切って全体を返す。`sink` があれば、読んだ行を伏せて流す。
      # ⚠ 全体はパイプの符号化のまま（`IO#read` と同じ）。不正なバイト列も、そのまま持つ。
      def drain(io, sink)
        return io.read unless sink
        buffer = String.new(encoding: io.external_encoding || Encoding.default_external)
        io.each_line do |line|
          buffer << line
          sink.write(masked(line))
        end
        return buffer
      end

      # ⚠ 例外の文言はパスなどを含みうるので、`masked` を通す。
      def log_stream_failure(error)
        @logger.warn(
          command: masked_to_s, error: error.class.name, message: masked(error.message),
          detail: 'stopped streaming the output; the command keeps running'
        )
      end
    end
  end
end
