# frozen_string_literal: true

module Ginseng
  class CommandLineTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @command = CommandLine.new
    end

    def test_args
      @command.args = []

      assert_empty(@command.args)
      @command.args = ['ffmpeg', File.join(Environment.dir, 'sample/poyke.mp4')]

      assert_equal('ffmpeg', @command.args[0])
    end

    def test_to_s
      @command.args = ['ls', 'a b', '"x"']

      assert_equal('ls a\\ b \\"x\\"', @command.to_s)
    end

    def test_dir
      assert_equal(@command.dir, Environment.dir)
      @command.dir = '/etc'
      @command.args = ['pwd']
      @command.exec

      # chdir が効くのは子プロセスだけ。親の Dir.pwd を見ていたため、この
      # アサーションは導入以来ずっと落ちていた。
      assert_equal('/etc', @command.stdout.chomp)
    end

    # 記録だけする logger。⚠ **伏せたかどうかは「出た行」でしか測れない**。
    class Recorder
      attr_reader :logs

      def initialize
        @logs = []
      end

      [:error, :warn, :info, :debug, :fatal].each do |severity|
        define_method(severity) do |message = nil|
          @logs.push([severity, message])
          return true
        end
      end
    end

    # 🔴🔴 **引数そのものが資格情報になる (#642)。**
    # ⚠⚠ `Masking#mask` はキー名で判定するので、`command:` の 1 つの文字列には効かない。
    def test_exec_masks_secrets_in_the_command
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      @command.secrets = ['s3cret']
      @command.args = ['echo', 'https://example.com/api/push/s3cret']
      @command.exec

      assert_equal('echo https://example.com/api/push/[FILTERED]', logger.logs.last.last[:command])
    end

    # ⚠⚠ **shellescape した形も伏せる (#642)。** `to_s` はエスケープ済みの文字列を返すので、
    # 🔴 生の形だけ見ていると**クォートされたときに黙って漏れる**。
    def test_masked_covers_the_escaped_form
      @command.secrets = ['a b']

      assert_equal('[FILTERED]', @command.masked('a\ b'))
      assert_equal('[FILTERED]', @command.masked('a b'))
    end

    # 🔴 **`env:` の値も伏せる (#642)。** ⚠⚠ 実測: キー名が `TOKEN` なら上流の
    # `mask` が落とすが、`PUSH_URL` のような名前だと**パスのトークンがそのまま出る**。
    def test_exec_masks_secrets_in_the_env
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      @command.secrets = ['s3cret']
      @command.env = {'PUSH_URL' => 'https://example.com/api/push/s3cret'}
      @command.args = ['echo', 'hello']
      @command.exec

      assert_equal({'PUSH_URL' => 'https://example.com/api/push/[FILTERED]'},
        logger.logs.last.last[:env])
    end

    # ⚠ **渡さなければ従来どおり (#642)。** 🔴 値の型（`nil` など）も変えない。
    # 🔴🔴 **secrets を渡しても String 以外の値の型を変えない（リリース前レビューの黄）。**
    # ⚠⚠ `child_env` は **`nil` を「その環境変数を外す」の意味で使う**ので、空文字に
    # 化けるとログが「空を渡した」に見える。
    def test_masked_env_keeps_non_string_values
      command = Ginseng::CommandLine.new(['true'])
      command.secrets = ['s3cret']
      command.env = {'A' => nil, 'B' => 42, 'C' => 'x s3cret'}

      env = command.send(:masked_env)

      assert_nil(env['A'], 'nil を空文字にしないこと')
      assert_equal(42, env['B'], '数値を文字列にしないこと')
      assert_equal("x #{Ginseng::Masking::FILTERED}", env['C'])
    end

    def test_exec_leaves_the_env_alone_without_secrets
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      @command.env = {'EMPTY' => nil}
      @command.args = ['echo', 'hello']
      @command.exec

      assert_equal({'EMPTY' => nil}, logger.logs.last.last[:env])
    end

    # 🔴🔴 **空文字・`nil` は落とす (#642)。**
    # ⚠⚠ 空文字で `gsub` すると**全文字の隙間に `[FILTERED]` が入る**。
    def test_secrets_ignores_blank_values
      @command.secrets = ['', nil, '  ']

      assert_empty(@command.secrets)
      assert_equal('hello', @command.masked('hello'))
    end

    # ⚠⚠ **長いものから伏せる (#642)。** 🔴 短い秘密が長い秘密の一部だと、
    # 先に短いほうを置換して `[FILTERED]def` のような中途半端な形になる。
    def test_masked_prefers_the_longest_secret
      @command.secrets = ['abc', 'abcdef']

      assert_equal('[FILTERED]', @command.masked('abcdef'))
    end

    # 🔴🔴 **正規化を迂回させない (#642 Codex P1)。**
    # ⚠⚠ `secrets << value` を許すと、空文字も順番の崩れも入り込む。
    def test_secrets_cannot_be_mutated_in_place
      @command.secrets = ['abc']

      assert_raise(FrozenError) {@command.secrets << 'abcdef'}
      assert_equal(['abc'], @command.secrets)
    end

    # 🔴 **渡された文字列を持ち回さない (#642 Codex P1)。**
    # ⚠⚠ `to_s` は String に対して自分を返すので、呼び出し側の書き換えが届く。
    def test_secrets_are_decoupled_from_the_caller
      secret = +'s3cret'
      @command.secrets = [secret]
      secret << 'X'

      assert_equal('[FILTERED]', @command.masked('s3cret'))
    end

    # 🔴🔴 **符号化が食い違っても落ちない (#642 Codex P2)。**
    #
    # ⚠⚠ UTF-8 の非 ASCII な秘密を Shift_JIS / BINARY の本文へそのまま当てると
    # `Encoding::CompatibilityError` になり、🔴 **コマンドは成功しているのに
    # `log_exec` が例外を上げる**。
    def test_masked_handles_other_encodings
      @command.secrets = ['秘密']

      assert_equal('コマンド [FILTERED]'.encode('Windows-31J'),
        @command.masked('コマンド 秘密'.encode('Windows-31J')))
      assert_equal('コマンド [FILTERED]'.dup.force_encoding('ASCII-8BIT'),
        @command.masked('コマンド 秘密'.dup.force_encoding('ASCII-8BIT')))
    end

    # ⚠ **その符号化で表せない秘密は、本文に現れようが無い (#642)。**
    # 🔴 飛ばしても伏せ損ねにはならないし、落ちてもいけない。
    def test_masked_skips_a_secret_that_cannot_appear
      @command.secrets = ['秘密']

      assert_equal('hello'.encode('US-ASCII'), @command.masked('hello'.encode('US-ASCII')))
    end

    def test_exec
      @command.args = ['ls', '/']
      @command.exec

      assert_predicate(@command.status, :zero?)
      assert_predicate(@command.stdout, :present?)
      assert_predicate(@command.stderr, :blank?)
      assert_kind_of(Integer, @command.pid)
    end

    def test_exec_system
      @command.args = ['ls', '/']

      assert(@command.exec_system)
    end

    def test_bundle_install
      @command.dir = Environment.dir

      assert(@command.bundle_install)
    end

    def test_exec_with_timeout
      @command.args = ['ls', '/']
      @command.exec(timeout: 10)

      assert_predicate(@command.status, :zero?)
      assert_predicate(@command.stdout, :present?)
    end

    def test_exec_timeout_expired
      @command.args = ['sleep', '10']

      assert_raise(Timeout::Error) do
        @command.exec(timeout: 1)
      end
    end

    # 🔴 **締切の時点で戻り、子を残さない**（pooza/mulukhiya-toot-proxy#4794）。
    # ⚠⚠ 以前は子が終わるまで例外が上がらなかった（`sleep 30` なら 30 秒後）。
    def test_exec_timeout_kills_the_child
      nap = unique_sleep
      @command.args = ['sh', '-c', nap]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator(elapsed, :<, 5)
      assert_empty(running(nap))
    end

    # ⚠ シェルが立てた孫まで止める。
    def test_exec_timeout_kills_the_grandchild
      nap = unique_sleep
      @command.args = ['sh', '-c', "(#{nap}; echo done) & wait"]

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      assert_empty(running(nap))
    end

    # 🔴 TERM を無視する相手は KILL で止める。⚠⚠ 先頭のシェルは TERM で先に死ぬので、
    # **先頭の終了を見て引き上げると本体が残る**。
    def test_exec_timeout_escalates_to_kill
      nap = unique_sleep
      @command.args = ['sh', '-c', "trap '' TERM; #{nap}; #{nap}"]

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      assert_empty(running(nap))
    end

    # ⚠ パイプのバッファ（64KB）を超える出力でも詰まらない。
    def test_exec_with_timeout_reads_large_output
      @command.args = ['sh', '-c', 'head -c 300000 /dev/zero | tr "\\0" a']

      assert_equal(0, @command.exec(timeout: 10))
      assert_equal(300_000, @command.stdout.bytesize)
    end

    # 🔴 先頭が締切の前に終わっても、パイプを握った子孫が残っていれば締切で止める
    # （pooza/mulukhiya-toot-proxy#4811 の Codex P1）。⚠ 出力の読み切りが締切の外にあると、ここで永久に戻らない。
    def test_deadline_covers_descendant_holding_the_pipe
      nap = unique_sleep
      @command.args = ['sh', '-c', "#{nap} &"]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator(elapsed, :<, 5)
      assert_empty(running(nap))
    end

    # 🔴 外側から `Thread#kill` で中断されても子を残さない（pooza/mulukhiya-toot-proxy#4811 の Codex P1）。
    # ⚠ ハンドラの締切は、実行中のスレッドを kill して切る。
    def test_child_is_killed_when_the_thread_is_killed
      nap = unique_sleep
      @command.args = ['sh', '-c', "trap '' TERM; #{nap}; #{nap}"]
      thread = Thread.new {@command.exec(timeout: 30)}
      sleep(0.5)
      thread.kill
      thread.join(5)

      assert_empty(running(nap))
    end

    # ⚠ 0 は「締切なし」（`Timeout.timeout(0)` と同じ意味・pooza/mulukhiya-toot-proxy#4811 の Codex P2）。
    def test_zero_timeout_means_no_deadline
      @command.args = ['sh', '-c', 'sleep 0.3; echo ok']

      assert_equal(0, @command.exec(timeout: 0))
      assert_equal("ok\n", @command.stdout)
    end

    # 🔴🔴 **止められない子がいても、締切で戻る (#684 Codex P1)。** ⚠⚠ 別のユーザーへ降りた子
    # （`sudo` 経由）へはシグナルが `EPERM` になる。`popen3` のブロック形式は出口で子を
    # 待つので、そのままだと**子が終わるまで戻らない**（`sleep 6` に 1 秒の締切で、戻るのは 6.0 秒後・実測）。
    # ⚠ 止めたことにしない — 文言と error の行で分かること。
    def test_exec_timeout_returns_even_if_the_child_cannot_be_signaled
      nap = unique_sleep
      @command.args = ['sh', '-c', nap]
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      original = deny_group_signals
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      # ⚠ 上限は 締切 0.5 ＋ 猶予 2 ＋ 見切り 1。**数字で書く**（定数から作ると、定数を
      # 変えても緑のままになる）。
      assert_operator(elapsed, :<, 5.5)
      assert_match(/still running/, error.message)
      assert_equal([:error, 'timed out, but the child could not be stopped'],
        [logger.logs.last.first, logger.logs.last.last[:message]])
      assert_not_empty(running_now(nap))
    ensure
      Process.define_singleton_method(:kill, original) if original
      `pkill -KILL -f '^#{nap}$'` if nap
    end

    # 🔴🔴 **先頭を回収したあとは、グループへシグナルを送らない (#684)。**
    #
    # ⚠⚠ 回収すると番号が空き、別のプロセスが引ける。そのあとで送ると、**無関係な
    # プロセスグループへ TERM / KILL が届く**（リリース前レビューで、番号の再利用を強制して
    # 実測した）。⚠ 再利用そのものは移植できる形で起こせないので、**順番**を固定する。
    # ⚠ 3 つの形: 普通の締切／先頭が先に終わり子孫がパイプを握る／外から中断される。
    def test_exec_timeout_never_signals_the_group_after_reaping
      [
        ['sh', '-c', unique_sleep],
        ['sh', '-c', "#{unique_sleep} &"],
        ['sh', '-c', "trap '' TERM; #{unique_sleep}; #{unique_sleep}"],
      ].each do |args|
        events = []
        restore = trace_process_calls(events)
        @command.args = args
        assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
        restore.call
        released = events.index {|event| event.first != :kill}

        assert_not_nil(released, args.last)
        assert_empty(events[(released + 1)..].select {|event| event.first == :kill}, args.last)
        assert_equal(:kill, events.first.first, args.last)
      ensure
        restore&.call
      end
    end

    # 🔴 **例外の文言にコマンドを載せない。** ⚠⚠ `secrets=` を使っていない利用側では、引数の
    # 資格情報がそのまま文言になる。文言はログと行き先が違う（通知・HTTP の応答）。
    # ⚠ コマンドは error の行に出し、`secrets` はそこでも伏せる (#642)。
    def test_exec_timeout_keeps_the_command_out_of_the_message
      @command.args = ['sh', '-c', "#{unique_sleep} # https://example.com/push/TOKEN123"]
      @command.secrets = ['TOKEN123']
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}

      assert_equal('execution expired (0.5s)', error.message)
      assert_match(/sleep/, logger.logs.last.last[:command])
      assert_match(/\[FILTERED\]/, logger.logs.last.last[:command])
      assert_no_match(/TOKEN123/, logger.logs.last.last.to_s)
    end

    # ⚠⚠ **TERM のあと、片付ける時間を残す。** 最初から KILL すると、相手は後始末を書けない。
    # ⚠ **締切までに出ていた出力は捨てない** — 相手が TERM で書いた末尾も `stderr` に残る。
    # 🔴 **止まったら、猶予を使い切らずに戻る。** ⚠⚠ 「グループが空か」で猶予を回すと、
    # 回収されていない孤児（ゾンビ）のぶん、止まっているのに最大 2 秒待つ（実測）。
    def test_exec_timeout_gives_the_child_time_to_clean_up
      nap = unique_sleep
      @command.args = ['sh', '-c', "trap 'echo cleanup >&2; exit 0' TERM; echo begun; #{nap} & wait"]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal("begun\n", @command.stdout)
      assert_equal("cleanup\n", @command.stderr)
      assert_nil(@command.status)
      assert_kind_of(Integer, @command.pid)
      assert_operator(elapsed, :<, 2.0)
      assert_empty(running(nap))
    end

    # ⚠ 標準エラー出力も、パイプのバッファ（64KB）を超えて詰まらない。
    def test_exec_with_timeout_reads_large_stderr
      @command.args = ['sh', '-c', 'head -c 300000 /dev/zero | tr "\\0" a >&2; echo ok']

      assert_equal(0, @command.exec(timeout: 10))
      assert_equal("ok\n", @command.stdout)
      assert_equal(300_000, @command.stderr.bytesize)
    end

    # ⚠⚠ **締切で抜けたとき、前の実行の結果を残さない。** 同じオブジェクトを使い回すと、
    # 締切になったのに `status` が 0、`stdout` が前回の出力のままだった。
    def test_exec_timeout_does_not_keep_the_previous_result
      flag = File.join(Dir.mktmpdir, 'slow')
      @command.args = ['sh', '-c', "test -e #{flag} && exec #{unique_sleep}; echo first"]

      assert_equal(0, @command.exec(timeout: 10))
      assert_equal("first\n", @command.stdout)
      previous = @command.pid
      FileUtils.touch(flag)

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      assert_nil(@command.status)
      assert_equal('', @command.stdout)
      assert_not_equal(previous, @command.pid)
    end

    # ⚠ 締切で抜けても、こちらの端のパイプを残さない。🔴 閉じ忘れると、止められなかった相手が
    # 終わるまで（GC が拾うまで）fd が残る。
    def test_exec_timeout_closes_its_pipes
      open_ios = lambda do
        ObjectSpace.each_object(IO).count do |io|
          !io.closed?
        rescue IOError
          false
        end
      end
      @command.args = ['sh', '-c', unique_sleep]
      GC.start
      before = open_ios.call

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      assert_operator(open_ios.call, :<=, before)
    end

    # 🔴 **プロセスグループを抜けた子孫も、止めたことにしない (#684 Codex P2)。**
    # ⚠⚠ `setsid` した子孫にはグループ宛てのシグナルが届かず、グループは空になる。
    # 「グループが空か」で決めると、動き続けているのに普通の締切として報告する。
    def test_exec_timeout_reports_a_descendant_that_left_the_group
      nap = unique_sleep
      escape = "Process.setsid; exec(*%w[#{nap}])"
      @command.args = ['sh', '-c', "#{RbConfig.ruby} -e '#{escape}' & wait"]
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 1.5)}
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator(elapsed, :<, 6.5)
      assert_match(/still running/, error.message)
      assert_equal(:error, logger.logs.last.first)
      assert_not_empty(running_now(nap))
    ensure
      `pkill -KILL -f '^#{nap}$'` if nap
    end

    # ⚠ 止められたときは、止められなかったときの文言を出さない（error は 1 行・`timed out`）。
    # 🔴 **回収されない孫（ゾンビ）が残っていても同じ。** ⚠⚠ CI のコンテナは PID 1 が孤児を
    # 回収しないので、止めた孫がゾンビとしてグループに残る。グループで決めると、ここが
    # 「まだ動いている」になる（手元では出ず、CI でだけ落ちた）。
    def test_exec_timeout_does_not_claim_still_running_for_killed_grandchildren
      nap = unique_sleep
      @command.args = ['sh', '-c', "(#{nap}; echo done) & (#{nap}) & wait"]
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}

      assert_equal('execution expired (0.5s)', error.message)
      assert_equal([[:error, 'timed out']],
        logger.logs.map {|severity, message| [severity, message[:message]]})
      assert_empty(running(nap))
    end

    def test_exec_timeout_does_not_claim_still_running_when_stopped
      @command.args = ['sh', '-c', unique_sleep]
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}

      assert_equal('execution expired (0.5s)', error.message)
      assert_equal([[:error, 'timed out']],
        logger.logs.map {|severity, message| [severity, message[:message]]})
    end

    # グループ宛て（負の番号）のシグナルを、全部 `EPERM` にする。元の実装を返す。
    def deny_group_signals
      original = Process.method(:kill)
      Process.define_singleton_method(:kill) do |signal, *pids|
        raise Errno::EPERM if pids.any?(&:negative?)
        original.call(signal, *pids)
      end
      return original
    end

    # ⚠ `running` と違って、消えるのを待たない。
    def running_now(command)
      return `pgrep -f '^#{command}$'`.split
    end

    # `Process.kill`（グループ宛て）・回収・`detach` の順番を記録する。元へ戻す手続きを返す。
    def trace_process_calls(events)
      originals = [:kill, :wait2, :detach].to_h {|name| [name, Process.method(name)]}
      Process.define_singleton_method(:kill) do |signal, *pids|
        events.push([:kill, signal]) if pids.any?(&:negative?) && signal != 0
        originals[:kill].call(signal, *pids)
      end
      Process.define_singleton_method(:wait2) do |*args|
        result = originals[:wait2].call(*args)
        events.push([:reaped]) if result
        result
      end
      Process.define_singleton_method(:detach) do |pid|
        events.push([:detached])
        originals[:detach].call(pid)
      end
      return -> {originals.each {|name, impl| Process.define_singleton_method(name, impl)}}
    end

    def unique_sleep
      return "sleep 30.#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}"
    end

    # ⚠ KILL はグループへ送った時点で戻る。孫が消えるまでの一瞬を待ってから数える。
    def running(command)
      pids = []
      20.times do
        pids = `pgrep -f '^#{command}$'`.split
        break if pids.empty?
        sleep(0.1)
      end
      return pids
    end

    def test_env
      @command.env = {HOGE: 'fugafuga'}
      @command.args = ['env']
      @command.exec

      assert_includes(@command.stdout, 'HOGE=fugafuga')
    end

    # Ruby パッチアップを跨ぐデプロイで、旧 Ruby の親から引き継いだ
    # RBENV_VERSION が子を旧 Ruby へ倒すのを防ぐ (#480)。
    def test_exec_does_not_inherit_rbenv_version
      original = ENV.fetch('RBENV_VERSION', nil)
      ENV['RBENV_VERSION'] = '0.0.0-should-not-leak'
      @command.args = ['env']
      @command.exec

      assert_not_includes(@command.stdout, 'RBENV_VERSION=')
    ensure
      ENV['RBENV_VERSION'] = original
    end

    # 呼び出し側が明示指定した場合はそちらを優先する。
    def test_env_overrides_unset
      @command.env = {RBENV_VERSION: '3.4.9'}
      @command.args = ['env']
      @command.exec

      assert_includes(@command.stdout, 'RBENV_VERSION=3.4.9')
    end

    def test_sudo_command_unsets_rbenv_version
      @command.user = 'nobody'
      @command.args = ['env']

      assert_includes(@command.send(:sudo_command), 'env -u RBENV_VERSION')
    end
  end
end
