# frozen_string_literal: true

module Ginseng
  class CommandLine
    # 締切つきの `exec` (#684)。締切が来たら子プロセスをグループごと止める。
    #
    # 🔴🔴 **こちらからは、プロセスグループの番号へシグナルを送らない。** ここの芯。
    # ⚠ 例外は 1 つだけ: 止められた番人を起こす CONT を、番人の pid へ（→ `wake`）。
    # ⚠⚠ グループ宛てのシグナルは**番号**へ送る。番号の持ち主が回収されると（グループに誰も
    # 残っていなければ）その番号は空き、**別のプロセスが引ける** — そのあとで送ると、
    # 🔴 **無関係なプロセスグループへ TERM / KILL が届く**（root の常駐なら、どのグループにも届く）。
    #
    # ⚠ 「送る前に持ち主を確かめる」では塞ぎきれない（2.4.0 のリリース前レビューと Codex の
    # P1 4 件が、順に突いた）。
    # - `Open3.popen3` は起こした瞬間に `Process.detach` するので、回収の時機を握れない
    #   （番号の再利用を強制して、誤爆を実測した）
    # - 自分で回収を握っても、**回収するのが自分だけとは限らない**（ホストが `SIGCHLD` を
    #   無視している・別のスレッドが `Process.wait(-1)` を回している）。回収せずに
    #   「まだ自分の子か」を確かめる手段が無い
    # - 生きた持ち主を置いて確かめてから送っても、**確かめてから送るまでの間**が残る
    #
    # ⚠⚠ **だから、グループの持ち主（番人）自身に送らせる。** 番人は何もしない小さな `sh` で、
    # コマンドをそのグループへ入れる。こちらは番人の標準入力へ命令を書くだけ。
    # - 番人が `kill 0`（自分のグループ宛て）を実行する瞬間、番人は必ず生きていて、番号は
    #   必ず番人のもの。**番号を取り違える余地が無い**
    # - 番人が居なければ（死んでいた）、命令は届かず、誰にも何も送られない
    # - コマンドは、いつ回収してもよい（番号と関係が無い）
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

      # コマンドの終了を見にいく間隔の上限（秒）。⚠ 1 ミリ秒から倍々で伸ばす。
      REAP_INTERVAL_MAX = 0.02

      # 番人。標準入力から命令を 1 行ずつ読み、**自分のグループへ**シグナルを送る。
      # - `TERM` / `KILL`: `kill -s <名前> 0`。⚠ KILL は自分も死ぬ
      # - それ以外・EOF: 終わる
      # - ⚠ TERM は自分では無視する（そうしないと、自分の TERM で死んで KILL を送れない）。
      #   コマンドが自分のグループへ撒きうるほかのシグナルも無視する（`kill -INT 0` など）
      # - ⚠ **止めるシグナルも無視する**（TSTP / TTIN / TTOU）。🔴 別のプロセスグループなので、
      #   端末を読もうとした子には TTIN がグループごと届く — 番人まで止まると、命令を読めない
      # - 🔴 SIGSTOP は無視できない。→ `wake`
      # - ⚠ `trap` は命令を読む前に済む（＝準備の前に TERM が飛ぶことは無い）
      # - ⚠ `/bin/sh` を直に指す（`PATH` に依らない。Ruby がシェル経由の文字列に使うのと同じ）
      KEEPER_SCRIPT = <<~SH.tr("\n", ' ').strip.freeze
        trap '' HUP INT QUIT TERM USR1 USR2 PIPE ALRM TSTP TTIN TTOU;
        while read order; do
          case "$order" in TERM|KILL) kill -s "$order" 0;; *) exit 0;; esac;
        done
      SH
      KEEPER = ['/bin/sh', '-c', KEEPER_SCRIPT].freeze

      # 起こした子。
      # - `keeper` / `gate`: 番人の pid と、その標準入力の書く側（命令を書く口）
      # - `status`: コマンドの終了状態（回収済みなら入る。横取りされたら `LOST`）
      Child = Struct.new(:keeper, :gate, :pid, :pipes, :status)

      # コマンドを、ほかの誰かに回収された印 (#684 Codex P1)。
      # ⚠ ホストが `SIGCHLD` を無視していたり、別のスレッドが `Process.wait(-1)` を回して
      # いたりすると、こちらの `wait2` は `Errno::ECHILD` になる。終了状態は分からない —
      # 間に合った実行も `Errno::ECHILD` で終わる（分からないものを成功にも失敗にもしない）。
      LOST = :lost

      # ⚠ **外へ約束しない。** 名前を変えると「名前が消える」＝メジャーになる。
      private_constant :KILL_GRACE_SECONDS, :DRAIN_GRACE_SECONDS, :REAP_INTERVAL_MAX,
        :KEEPER_SCRIPT, :KEEPER, :Child, :LOST

      private

      # ⚠ 締切として扱うのは正の数だけ。0 / nil は締切なし。
      def deadline?(timeout)
        return timeout.is_a?(Numeric) && timeout.positive?
      end

      def capture_until(timeout)
        deadline = monotonic + timeout
        child = nil
        uninterruptible {child = spawn_group}
        readers = child.pipes.map {|io| reader(io)}
        unless await(child, readers, deadline)
          terminate(child, readers)
          expire!(child, readers, timeout)
        end
        @stdout, @stderr = readers.map(&:value)
        @status = exit_status(child)
      ensure
        # 🔴 **外から `Thread#kill` で中断されても、子を残さない。** ⚠ 締切の猶予の途中で
        # 外側の締切に切られると、後始末ごと飛ばされる。ここは待たずに KILL する。
        uninterruptible {release(child, readers)} if child
      end

      # 🔴🔴 **「起こした／回収した」と、その記録の間で中断させない (#684 Codex P1)。**
      # ⚠⚠ 外からの `Thread#kill` は、メソッドが値を返してから変数へ入るまでの間にも届く。
      # - 起こした直後に届くと、誰も覚えておらず、子と番人が残る
      # - 回収の直後に届くと、終わった実行を「終わっていない」と読んで KILL する
      # ⚠ 中で待つ処理をしないこと（中断が、その間ずっと届かなくなる）。
      # 🔴 **スレッドは、作られたときの「中断不可」を引き継ぐ。** 区間の中で作るスレッドは、
      # 自分で中断可能へ戻すこと（→ `reader` / `forget`）。
      def uninterruptible(&)
        return Thread.handle_interrupt(Object => :never, &)
      end

      # 出力を読み切るスレッド。
      #
      # 🔴 **中断可能へ戻してから読む。** ⚠⚠ 呼び出し側が中断不可の区間から `exec` を呼ぶと、
      # 読み手がそれを引き継いで `kill` が効かなくなり、パイプを閉じる側が読み手を待って、
      # **止められなかった相手が終わるまで戻らない**（実測: 上限 3.3 秒のはずが 8.7 秒）。
      def reader(io)
        return Thread.new {Thread.handle_interrupt(Object => :immediate) {io.read}}
      end

      # ⚠⚠ **プロセスグループごと起こす。** `to_s` はシェルを経由しうるので、子の番号だけに
      # シグナルを送ると**シェルだけが死んで本体が残る**。
      # ⚠ 標準入力は空（`Open3.capture3` に何も渡さないのと同じで、読めばすぐ EOF）。
      # 🔴 **別のプロセスグループなので、子は端末から入力できない**（`sudo` のパスワード入力は
      # 止まったまま締切を迎える）。
      def spawn_group
        gate_r, gate_w = IO.pipe
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        keeper = Process.spawn(*KEEPER, pgroup: true, in: gate_r, out: File::NULL, err: File::NULL)
        pid = Process.spawn(*spawn_args, chdir: dir, pgroup: keeper,
          in: File::NULL, out: out_w, err: err_w)
        return Child.new(keeper, gate_w, pid, [out_r, err_r])
      ensure
        # ⚠ 子へ渡した端は必ず閉じる — こちらが握ったままだと、読み手が EOF に達しない。
        [gate_r, out_w, err_w].each {|io| io&.close}
        discard(Child.new(keeper, gate_w, nil, [out_r, err_r])) unless pid
      end

      # ⚠ コマンドを起こせなかったとき（存在しないコマンド・無い `chdir` 先）の後始末。
      # ⚠ ここでも番人に「終われ」と書く（閉じるだけに頼らない。→ `release`）。
      def discard(child)
        order(child, 'EXIT') if child.keeper
        [child.gate, *child.pipes].each {|io| io&.close}
        forget(child.keeper) if child.keeper
      end

      # 終わるのを待たずに手放す（回収だけ別スレッドに任せる）。
      #
      # 🔴🔴 **`Process.detach` を、中断不可の区間（`uninterruptible`）の中で呼ばない。**
      # ⚠⚠ `Process.detach` が作る回収用のスレッドが中断不可を引き継ぐと、Ruby は終了時に
      # それを止められず、🔴 **相手が終わるまでホストのプロセスが終了できない**（止められ
      # なかった子が居座るあいだ、ずっと）。
      # 実測: 区間の中で `detach` した 6.8 秒の子に対して、終了まで 6.9 秒。
      # ⚠ だから自前のスレッドにして、**その中で中断可能へ戻す**。
      def forget(pid)
        Thread.new do
          Thread.handle_interrupt(Object => :immediate) {Process.wait(pid)}
        rescue Errno::ECHILD
          nil
        end
      end

      # 出力の読み切りと、コマンドの終了を締切まで待つ。間に合えば終了状態、でなければ nil。
      #
      # ⚠⚠ **出力を読み切るところまで締切に含める。** コマンドが終わっても、パイプを握った
      # 子孫（`sh -c 'sleep 30 &'`）が残っていると読み手は戻らない。
      # ⚠ 出力を出さないコマンドでは、読み手はコマンドが終わるまで戻らないので、待ち方は変わらない。
      def await(child, readers, deadline)
        return nil unless drained?(readers, deadline)
        return reap(child, deadline)
      end

      # 出力のパイプが両方とも閉じたか（＝生きている書き手が 1 つも残っていないか）。
      def drained?(readers, deadline)
        return readers.all? {|reader| reader.join(remaining(deadline))}
      end

      # コマンドを回収する。`deadline` までに終わらなければ nil（回収しない）。
      # ⚠ 回収と、`child.status` への記録は 1 つの区間（→ `uninterruptible`）。
      # ⚠ 横取りされていたら `LOST` を記録して返す（ここでは例外にしない — 締切の経路では、
      # このあと `Timeout::Error` を上げる）。
      def reap(child, deadline)
        interval = 0.001
        loop do
          uninterruptible {child.status = wait_child(child.pid)}
          return child.status if child.status
          return nil if monotonic >= deadline
          sleep([interval, remaining(deadline)].min)
          interval = [interval * 2, REAP_INTERVAL_MAX].min
        end
      end

      def wait_child(pid)
        return Process.wait2(pid, Process::WNOHANG)&.last
      rescue Errno::ECHILD
        return LOST
      end

      # ⚠ 間に合ったのに終了状態が分からない（→ `LOST`）ときは、分からないと言う。
      def exit_status(child)
        return child.status unless child.status == LOST
        raise Errno::ECHILD, "pid #{child.pid} was reaped by someone else"
      end

      # 締切を過ぎた子をプロセスグループごと止める。
      #
      # ⚠ TERM のあと、**出力が閉じてコマンドも終わったら**そこで引き上げる（KILL は送らない）。
      # 猶予の間にそうならなければ KILL。
      # ⚠ 送れない（`EPERM`）相手・グループを抜けた相手には届かないが、ここでは気にしない —
      # 止まったかは、呼び出し側がパイプを見て決める。
      def terminate(child, readers)
        order(child, 'TERM')
        deadline = monotonic + KILL_GRACE_SECONDS
        reap(child, deadline) if drained?(readers, deadline)
        order(child, 'KILL') unless finished?(child, readers)
      end

      # コマンドを回収済みで、出力も読み切ったか。
      def finished?(child, readers)
        return !child.status.nil? && readers.none?(&:alive?)
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

      # ⚠ 終わっていなければ KILL、終わっていれば番人だけ終わらせて、手放す。
      # ⚠ 番人には「終われ」と書く — 🔴 **標準入力を閉じるだけに頼らない。** 実行の最中に
      # ホストが `fork` していると、その子が書く側の端を継いでいて、こちらが閉じても
      # 番人に EOF が届かない（fork した子が終わるまで番人が残る・実測）。
      # ⚠ 回収は別スレッドに任せる（→ `forget`）。
      # ⚠ 読み手を止めてからパイプを閉じる。🔴 閉じ忘れると、止められなかった相手が終わるまで
      # 読み手のスレッドとパイプが残る。⚠ 相手の側は、次に書いたとき `SIGPIPE`
      # （無視していれば `EPIPE`）を受ける。
      def release(child, readers)
        order(child, readers && finished?(child, readers) ? 'EXIT' : 'KILL')
        child.gate.close unless child.gate.closed?
        forget(child.keeper)
        forget(child.pid) unless child.status
        readers&.each {|reader| reader.kill if reader.alive?}
        child.pipes.each {|io| io.close unless io.closed?}
      end

      # 番人へ命令を書く。
      #
      # ⚠ 番人が居ない（KILL を命じたあと・誰かに殺された）ときは `EPIPE` になる。
      # そのときは何もしない — 🔴 **代わりにこちらから送らない**（冒頭）。
      def order(child, word)
        wake(child)
        child.gate.syswrite("#{word}\n")
      rescue Errno::EPIPE, IOError
        return nil
      end

      # 番人が止められていたら、起こす (#684 Codex P1)。
      #
      # 🔴 **グループごと STOP されると、番人も止まって命令を読めない**（コマンドが
      # `kill -STOP 0` を撒く・外から止められる）。⚠ SIGSTOP は無視も trap もできない。
      # ⚠⚠ **送るのは CONT を、番人の pid へだけ。** こちらから送る唯一のシグナル。
      # - **番人が終わったと分かっていない限り、送る。** 動いている相手への CONT は何も
      #   起こさない。🔴 「止まっていると分かったら送る」にしない — 止まったという知らせは
      #   1 回しか届かず、ホストの別の待ち手（`WUNTRACED`）が先に受け取っていると、
      #   止まっているのに分からない (Codex P2)
      # - 送る前に `wait2` を訊く。終わっていた（いま回収した）・誰かに回収された（`ECHILD`）
      #   なら送らない
      # - 万一番号を取り違えても、届くのは CONT（止まっていた誰かが動き出すだけ）
      # ⚠ コマンドの側は止まったままでよい — KILL は止まっている相手にも効く。
      def wake(child)
        uninterruptible do
          flags = Process::WNOHANG | Process::WUNTRACED
          status = Process.wait2(child.keeper, flags)&.last
          Process.kill('CONT', child.keeper) if status.nil? || status.stopped?
        end
      rescue Errno::ECHILD, Errno::ESRCH
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
