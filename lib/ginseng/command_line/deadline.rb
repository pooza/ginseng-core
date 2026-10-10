# frozen_string_literal: true

module Ginseng
  class CommandLine
    # 締切つきの `exec` (#684)。締切が来たら子プロセスをグループごと止める。
    #
    # 🔴🔴 **先頭の子は、シグナルを送り終えるまで回収しない。** ここの芯。
    # ⚠⚠ グループ宛てのシグナルは**番号**へ送る。先頭を回収すると（グループに誰も残って
    # いなければ）その番号は空き、**別のプロセスが引ける** — そのあとで送ると、🔴 **無関係な
    # プロセスグループへ TERM / KILL が届く**（root の常駐なら、どのグループにも届く）。
    # 回収前の先頭はゾンビでも番号を押さえているので、**回収するまでは必ず自分のグループに当たる**。
    # ⚠ だから `Open3.popen3` を使わない — あれは起こした瞬間に `Process.detach` して、
    # 回収の時機をこちらから握れなくする（2.4.0 のリリース前レビューで、番号の再利用を
    # 強制して誤爆を実測した）。
    #
    # 🔴 **「止まったか」「猶予を使い切ったか」は、出力のパイプで測る。**
    # - ⚠⚠ **プロセスグループはゾンビも数える。** 回収されていない孤児（付け替わった親が
    #   回収するまで。コンテナで PID 1 が回収しなければずっと）は `kill(0, -pgid)` が通る。
    #   グループで測ると、**止めたものを「まだ動いている」と読む**（CI で実際に出た）うえ、
    #   止まっているのに猶予いっぱい待つ（普通のデスクトップでも 0.5〜1 秒遅れた）
    # - ⚠⚠ **グループを抜けた子孫（`setsid`）は、グループからは見えない。**
    # ⚠ 生きている書き手が 1 つでもパイプを握っていれば、読み手は戻らない。ゾンビは握らない。
    # 🔴 **限界**: 出力を閉じて（付け替えて）居座る相手は、ここからは見えない。
    module Deadline
      # 締切で TERM を送ってから、KILL に切り替えるまでの猶予（秒）。
      KILL_GRACE_SECONDS = 2

      # KILL を送ってから、出力のパイプが閉じるのを待つ上限（秒）。⚠ 止められない相手を
      # 見切るまでの時間でもある。
      DRAIN_GRACE_SECONDS = 1

      # 先頭の終了を見にいく間隔の上限（秒）。⚠ 1 ミリ秒から倍々で伸ばす。
      REAP_INTERVAL_MAX = 0.02

      # 起こした子。⚠ **`status` が入っている ＝ 先頭を回収済み**（もうシグナルを送らない）。
      Child = Struct.new(:pid, :pipes, :status)

      # ⚠ **外へ約束しない。** 名前を変えると「名前が消える」＝メジャーになる。
      private_constant :KILL_GRACE_SECONDS, :DRAIN_GRACE_SECONDS, :REAP_INTERVAL_MAX, :Child

      private

      # ⚠ 締切として扱うのは正の数だけ。0 / nil は締切なし。
      def deadline?(timeout)
        return timeout.is_a?(Numeric) && timeout.positive?
      end

      def capture_until(timeout)
        deadline = monotonic + timeout
        child = nil
        uninterruptible {child = spawn_group}
        readers = child.pipes.map {|io| Thread.new {io.read}}
        unless await(child, readers, deadline)
          terminate(child, readers)
          expire!(child, readers, timeout)
        end
        @stdout, @stderr = readers.map(&:value)
        @status = child.status
      ensure
        # 🔴 **外から `Thread#kill` で中断されても、子を残さない。** ⚠ 締切の猶予の途中で
        # 外側の締切に切られると、後始末ごと飛ばされる。ここは待たずに KILL する。
        uninterruptible {release(child, readers)} if child
      end

      # 🔴🔴 **「起こした／回収した」と、その記録の間で中断させない (#684 Codex P1)。**
      # ⚠⚠ 外からの `Thread#kill` は、メソッドが値を返してから変数へ入るまでの間にも届く。
      # - 回収の直後に届くと、**回収済みなのに未回収と読んで、空いたかもしれない番号へ KILL する**
      #   （冒頭の誤爆が、ここだけ残る）
      # - 起こした直後に届くと、番号を誰も覚えておらず、子が残る
      # ⚠ 中で待つ処理をしないこと（中断が、その間ずっと届かなくなる）。
      def uninterruptible(&)
        return Thread.handle_interrupt(Object => :never, &)
      end

      # ⚠⚠ **プロセスグループごと起こす。** `to_s` はシェルを経由しうるので、子の番号だけに
      # シグナルを送ると**シェルだけが死んで本体が残る**。
      # ⚠ 標準入力は空（`Open3.capture3` に何も渡さないのと同じで、読めばすぐ EOF）。
      # 🔴 **別のプロセスグループなので、子は端末から入力できない**（`sudo` のパスワード入力は
      # 止まったまま締切を迎える）。
      def spawn_group
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = Process.spawn(*spawn_args, chdir: dir, pgroup: true,
          in: File::NULL, out: out_w, err: err_w)
        return Child.new(pid, [out_r, err_r])
      ensure
        # ⚠ 書く側の端は必ず閉じる — こちらが握ったままだと、読み手が EOF に達しない。
        [out_w, err_w].each {|io| io&.close}
        [out_r, err_r].each {|io| io&.close} unless pid
      end

      # 出力の読み切りと、先頭の終了を締切まで待つ。間に合えば先頭の終了状態、でなければ nil。
      #
      # ⚠⚠ **出力を読み切るところまで締切に含める。** 先頭が終わっても、パイプを握った子孫
      # （`sh -c 'sleep 30 &'`）が残っていると読み手は戻らない。
      # 🔴 **先に読み切りを待ち、先頭はそのあとで回収する。** 逆にすると、先頭を回収した
      # あとで締切が来て、空いたかもしれない番号へシグナルを送ることになる。
      # ⚠ 出力を出さないコマンドでは、読み手は先頭が終わるまで戻らないので、待ち方は変わらない。
      def await(child, readers, deadline)
        return nil unless drained?(readers, deadline)
        return reap(child, deadline)
      end

      # 出力のパイプが両方とも閉じたか（＝生きている書き手が 1 つも残っていないか）。
      def drained?(readers, deadline)
        return readers.all? {|reader| reader.join(remaining(deadline))}
      end

      # 先頭を回収する。`deadline` までに終わらなければ nil（回収しない）。
      # ⚠ 回収と、`child.status` への記録は 1 つの区間（→ `uninterruptible`）。
      def reap(child, deadline)
        interval = 0.001
        loop do
          uninterruptible {child.status = Process.wait2(child.pid, Process::WNOHANG)&.last}
          return child.status if child.status
          return nil if monotonic >= deadline
          sleep([interval, remaining(deadline)].min)
          interval = [interval * 2, REAP_INTERVAL_MAX].min
        end
      end

      # 締切を過ぎた子をプロセスグループごと止める。
      #
      # ⚠ TERM のあと、**出力が閉じて先頭も終わったら**そこで引き上げる（KILL は送らない）。
      # 🔴 先頭を回収したあとは、もう送らない（冒頭）。⚠ 猶予の間に終わらなければ KILL。
      # ⚠ 送れない（`EPERM`）相手・グループを抜けた相手には届かないが、ここでは気にしない —
      # 止まったかは、呼び出し側がパイプを見て決める。
      def terminate(child, readers)
        signal_group('TERM', child.pid)
        deadline = monotonic + KILL_GRACE_SECONDS
        reap(child, deadline) if drained?(readers, deadline)
        signal_group('KILL', child.pid) unless child.status
      end

      # 🔴🔴 **止められなかったことを、止めたことにしない (#684 Codex P1 / P2)。**
      # ⚠ 例外のクラスは同じ（呼び出し側の `rescue Timeout::Error` を壊さない）。違いは
      # 文言の `still running` と、error の行の `message:`。
      #
      # ⚠⚠ **文言にコマンドを載せない。** `secrets=` を使っていない利用側では、引数の
      # 資格情報がそのまま例外の文言になる — 🔴 文言はログと行き先が違う（通知・HTTP の応答）。
      # ⚠ コマンドは error の行に出す（`Logger` のマスクを通る）。
      #
      # ⚠ **締切までに出ていた出力は捨てない。** 読み終えた分を `stdout` / `stderr` に残す
      # （ffmpeg が TERM で出す末尾など、診断に要る）。読み終えていない側は nil。
      def expire!(child, readers, timeout)
        stopped = drained?(readers, monotonic + DRAIN_GRACE_SECONDS)
        @pid = pid = child.pid
        @stdout, @stderr = readers.map {|reader| reader.value unless reader.alive?}
        log_expired(pid, timeout, stopped:)
        detail = stopped ? '' : "; still running: output still held, pid #{pid}"
        raise Timeout::Error, "execution expired (#{timeout}s#{detail})"
      end

      def log_expired(pid, timeout, stopped:)
        @logger.error(
          command: masked(to_s), dir:, env: masked_env, user: @user, pid:, timeout:,
          message: stopped ? 'timed out' : 'timed out, but the child could not be stopped'
        )
      end

      # ⚠ 未回収なら KILL してから手放す。**回収は `Process.detach` に任せ、以後は送らない。**
      # ⚠ 読み手を止めてからパイプを閉じる。🔴 閉じ忘れると、止められなかった相手が終わるまで
      # 読み手のスレッドとパイプが残る。⚠ 相手の側は、次に書いたとき `SIGPIPE`
      # （無視していれば `EPIPE`）を受ける。
      def release(child, readers)
        unless child.status
          signal_group('KILL', child.pid)
          Process.detach(child.pid)
        end
        readers&.each {|reader| reader.kill if reader.alive?}
        child.pipes.each {|io| io.close unless io.closed?}
      end

      # ⚠ `pgroup: true` で起こしているので、プロセスグループの番号は先頭の pid と同じ。
      # ⚠ 既に居ない（`ESRCH`）・送れない（`EPERM`）は、ここでは何もしない。
      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        return nil
      end

      def remaining(deadline)
        return [deadline - monotonic, 0].max
      end

      def monotonic
        return Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
