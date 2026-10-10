# frozen_string_literal: true

module Ginseng
  class CommandLine
    # 締切つきの `exec` (#684)。締切が来たら子プロセスをグループごと止める。
    #
    # 🔴🔴 **グループの番号は、こちらが握る「生きた」プロセス（番人）に押さえさせる。** ここの芯。
    # ⚠⚠ グループ宛てのシグナルは**番号**へ送る。番号の持ち主が回収されると（グループに誰も
    # 残っていなければ）その番号は空き、**別のプロセスが引ける** — そのあとで送ると、
    # 🔴 **無関係なプロセスグループへ TERM / KILL が届く**（root の常駐なら、どのグループにも届く）。
    #
    # ⚠ コマンド自身を持ち主にすると、守れない場面が残る（2.4.0 のリリース前レビューと
    # Codex の P1 3 件が、順に突いた）。
    # - `Open3.popen3` は起こした瞬間に `Process.detach` するので、回収の時機を握れない
    #   （番号の再利用を強制して、誤爆を実測した）
    # - 自分で回収を握っても、**回収するのが自分だけとは限らない。** ホストが `SIGCHLD` を
    #   無視していたり、別のスレッドが `Process.wait(-1)` を回していたりすると、終わった子は
    #   先に回収される。🔴 **回収せずに「まだ自分の子か」を確かめる手段が無い**
    #
    # ⚠⚠ **生きているプロセスは、誰にも回収できない。** だから番人には何もさせず
    # （標準入力が閉じるまで待つだけ・TERM は無視）、コマンドをそのグループへ入れる。
    # - 送る前に番人が生きているかを確かめる（`wait2` + `WNOHANG` が nil）。生きていれば、
    #   番号は確かに自分のもの
    # - コマンドは、いつ回収してもよい（番号と関係が無い）
    # - 🔴 **KILL は 1 回だけ。** 番人も一緒に死ぬので、それ以後は送らない
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

      # 番人。⚠ TERM は無視する（グループ宛ての TERM で一緒に死ぬと、KILL を送る前に
      # 番号が空く）。標準入力が閉じたら終わる。
      KEEPER = ['sh', '-c', "trap '' TERM; read _"].freeze

      # 起こした子。
      # - `keeper` / `gate`: 番人の pid（＝グループの番号）と、その標準入力の書く側
      # - `held`: 番人が生きていると信じてよいか。⚠ **偽になったら、もう送らない**
      # - `status`: コマンドの終了状態（回収済みなら入る。横取りされたら `LOST`）
      Child = Struct.new(:keeper, :gate, :pid, :pipes, :held, :status)

      # コマンドを、ほかの誰かに回収された印。⚠ 終了状態は分からない — 間に合った実行も
      # `Errno::ECHILD` で終わる（分からないものを成功にも失敗にもしない）。
      LOST = :lost

      # ⚠ **外へ約束しない。** 名前を変えると「名前が消える」＝メジャーになる。
      private_constant :KILL_GRACE_SECONDS, :DRAIN_GRACE_SECONDS, :REAP_INTERVAL_MAX,
        :KEEPER, :Child, :LOST

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
        @status = exit_status(child)
      ensure
        # 🔴 **外から `Thread#kill` で中断されても、子を残さない。** ⚠ 締切の猶予の途中で
        # 外側の締切に切られると、後始末ごと飛ばされる。ここは待たずに KILL する。
        uninterruptible {release(child, readers)} if child
      end

      # 🔴🔴 **「起こした／確かめた／送った」と、その記録の間で中断させない (#684 Codex P1)。**
      # ⚠⚠ 外からの `Thread#kill` は、メソッドが値を返してから変数へ入るまでの間にも届く。
      # - 起こした直後に届くと、番号を誰も覚えておらず、子が残る
      # - KILL を送った直後に届くと、番人が死んだことを覚えておらず、もう 1 回送る
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
        gate_r, gate_w = IO.pipe
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        keeper = Process.spawn(*KEEPER, pgroup: true, in: gate_r, out: File::NULL, err: File::NULL)
        pid = Process.spawn(*spawn_args, chdir: dir, pgroup: keeper,
          in: File::NULL, out: out_w, err: err_w)
        return Child.new(keeper, gate_w, pid, [out_r, err_r], true)
      ensure
        # ⚠ 子へ渡した端は必ず閉じる — こちらが握ったままだと、読み手が EOF に達しない。
        [gate_r, out_w, err_w].each {|io| io&.close}
        discard(keeper, [gate_w, out_r, err_r]) unless pid
      end

      # ⚠ コマンドを起こせなかったとき（存在しないコマンド・無い `chdir` 先）の後始末。
      def discard(keeper, pipes)
        pipes.each {|io| io&.close}
        forget(keeper) if keeper
      end

      # 終わるのを待たずに手放す（回収だけ別スレッドに任せる）。
      #
      # 🔴🔴 **`Process.detach` を、中断不可の区間（`uninterruptible`）の中で呼ばない。**
      # ⚠⚠ スレッドは、作られたときの「中断不可」を**引き継ぐ**。`Process.detach` が作る
      # 回収用のスレッドがそうなると、Ruby は終了時にそれを止められず、🔴 **相手が終わるまで
      # ホストのプロセスが終了できない**（止められなかった子が居座るあいだ、ずっと）。
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
        signal_group(child, 'TERM')
        deadline = monotonic + KILL_GRACE_SECONDS
        reap(child, deadline) if drained?(readers, deadline)
        signal_group(child, 'KILL') unless finished?(child, readers)
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

      # ⚠ 終わっていなければ KILL してから手放す。🔴 **番人の標準入力を閉じたら、以後は送らない**
      # （番人が終わって、番号が空く）。⚠ 回収は別スレッドに任せる（→ `forget`）。
      # ⚠ 読み手を止めてからパイプを閉じる。🔴 閉じ忘れると、止められなかった相手が終わるまで
      # 読み手のスレッドとパイプが残る。⚠ 相手の側は、次に書いたとき `SIGPIPE`
      # （無視していれば `EPIPE`）を受ける。
      def release(child, readers)
        signal_group(child, 'KILL') unless readers && finished?(child, readers)
        child.held = false
        child.gate.close unless child.gate.closed?
        forget(child.keeper)
        forget(child.pid) unless child.status
        readers&.each {|reader| reader.kill if reader.alive?}
        child.pipes.each {|io| io.close unless io.closed?}
      end

      # グループへシグナルを送る。🔴 **番人が生きていると確かめられたときだけ。**
      #
      # ⚠ 確かめる・送る・覚えるは 1 つの区間（→ `uninterruptible`）。
      # ⚠ 既に居ない（`ESRCH`）・送れない（`EPERM`）は、ここでは何もしない。
      def signal_group(child, signal)
        uninterruptible do
          next unless keeping?(child)
          child.held = false if signal == 'KILL'
          Process.kill(signal, -child.keeper)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      # 番人は生きているか（＝グループの番号は、まだ自分のものか）。
      #
      # ⚠⚠ **nil（まだ終わっていない）だけを「生きている」と読む。** 終了状態が返った
      # （終わっていたので、いま回収した）・`ECHILD`（誰かに回収された）は、どちらも
      # 番号を手放したということ。🔴 一度偽になったら戻さない。
      def keeping?(child)
        return false unless child.held
        child.held = Process.wait2(child.keeper, Process::WNOHANG).nil?
        return child.held
      rescue Errno::ECHILD
        child.held = false
        return false
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
