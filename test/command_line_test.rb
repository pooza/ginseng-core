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

    # 🔴🔴 **グループの番号を手放したあとは、そこへシグナルを送らない (#684)。**
    #
    # ⚠⚠ 番号の持ち主が回収されると番号が空き、別のプロセスが引ける。そのあとで送ると、
    # **無関係なプロセスグループへ TERM / KILL が届く**（リリース前レビューで、番号の再利用を
    # 強制して実測した）。⚠ 再利用そのものは移植できる形で起こせないので、**順番**を固定する。
    # ⚠ 3 つの形: 普通の締切／コマンドが先に終わり子孫がパイプを握る／TERM を無視する。
    # 🔴 **KILL は 1 回だけ**（番人も一緒に死ぬので、2 回目は空いた番号へ飛ぶ）。
    def test_exec_timeout_never_signals_the_group_after_releasing_it
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
        kills = events.select {|event| event.first == :kill}

        assert_no_signal_after_release(events, args.last)
        assert_equal('TERM', kills.first[1], args.last)
        assert_operator(kills.count {|event| event[1] == 'KILL'}, :<=, 1, args.last)
        assert_equal(1, kills.map(&:last).uniq.size, args.last)
      ensure
        restore&.call
      end
    end

    # ⚠ TERM を無視する相手には KILL まで進む。そのあと手放すときに、もう 1 回送らない。
    def test_exec_timeout_sends_kill_only_once
      events = []
      restore = trace_process_calls(events)
      @command.args = ['sh', '-c', "trap '' TERM; #{unique_sleep}; #{unique_sleep}"]

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      assert_equal(['TERM', 'KILL'], events.select {|event| event.first == :kill}.map {|event| event[1]})
    ensure
      restore&.call
    end

    # 🔴 **KILL を送ったら、番人がまだ生きて見えても、もう送らない。**
    # ⚠⚠ KILL の直後は、番人がまだ死にきっていないことがある（`wait2` が nil を返す）。
    # 「生きているから番号は自分のもの」と読むと、2 回目の KILL が、番人が消えて空いた
    # 番号へ飛ぶ。⚠ KILL のあと、番人が生きて見え続ける形を作って測る。
    def test_exec_timeout_does_not_trust_the_keeper_after_kill
      events = []
      restore = trace_process_calls(events)
      traced = Process.method(:wait2)
      Process.define_singleton_method(:wait2) do |pid, *args|
        next nil if events.include?([:kill, 'KILL', pid])
        traced.call(pid, *args)
      end
      @command.args = ['sh', '-c', "trap '' TERM; #{unique_sleep}; #{unique_sleep}"]

      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      assert_equal(['TERM', 'KILL'], events.select {|event| event.first == :kill}.map {|event| event[1]})
    ensure
      restore&.call
    end

    # 🔴🔴 **番号の持ち主を確かめられなければ、1 つも送らない (#684 Codex P1)。**
    #
    # ⚠⚠ ホストが `SIGCHLD` を無視していたり、別のスレッドが `Process.wait(-1)` を回して
    # いたりすると、終わった子は先に回収され、こちらの `wait2` は `Errno::ECHILD` になる。
    # 🔴 コマンド自身を番号の持ち主にしていると、**出力を握った子孫が残っているあいだは
    # 回収しにいかないので、横取りに気づかないまま TERM / KILL を送る**。
    # ⚠ 番人が居ない（確かめたら `ECHILD`）形を作り、締切を迎えさせる。
    def test_exec_timeout_sends_nothing_when_the_group_cannot_be_confirmed
      nap = unique_sleep
      events = []
      restore = trace_process_calls(events)
      Process.define_singleton_method(:wait2) {|*| raise Errno::ECHILD}
      @command.args = ['sh', '-c', nap]

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}

      assert_empty(events.select {|event| event.first == :kill})
      assert_match(/still running/, error.message)
    ensure
      restore&.call
      `pkill -KILL -f '^#{nap}$'` if nap
    end

    # ⚠ コマンドを誰かに回収されたら、終了状態は分からない。間に合った実行も
    # `Errno::ECHILD` で終わる（成功にも失敗にもしない）。⚠ このときも送らない。
    def test_command_reaped_by_someone_else_raises_echild
      events = []
      restore = trace_process_calls(events)
      Process.define_singleton_method(:wait2) {|*| raise Errno::ECHILD}
      @command.args = ['sh', '-c', 'echo ok']

      error = assert_raise(Errno::ECHILD) {@command.exec(timeout: 10)}

      assert_match(/reaped by someone else/, error.message)
      assert_empty(events.select {|event| event.first == :kill})
    ensure
      restore&.call
    end

    # 🔴 **回収した直後に中断されても、終わった実行へ KILL を送らない (#684 Codex P1)。**
    # ⚠⚠ 外からの `Thread#kill` は、回収が値を返してから記録されるまでの間にも届く。
    # 記録が飛ぶと「終わっていない」と読んで、KILL する。
    # ⚠ 回収が成功したその場で、実行中のスレッドを別スレッドから kill して測る。
    def test_interruption_right_after_reaping_does_not_signal_the_group
      events = []
      restore = trace_process_calls(events)
      traced = Process.method(:wait2)
      target = nil
      Process.define_singleton_method(:wait2) do |*args|
        result = traced.call(*args)
        Thread.new {target.kill}.join if result
        result
      end
      @command.args = ['sh', '-c', 'echo ok']
      target = Thread.new {@command.exec(timeout: 10)}
      target.join(5)

      assert_empty(events.select {|event| event.first == :kill})
      assert_equal(1, events.count {|event| event.first == :reaped})
    ensure
      restore&.call
    end

    # 🔴🔴 **止められなかった子が居座っていても、ホストのプロセスは終了できる。**
    #
    # ⚠⚠ 回収用のスレッドを中断不可の区間で作ると、Ruby は終了時にそれを止められず、
    # **相手が終わるまでプロセスが終わらない**（常駐の再起動が、子の完走を待つことになる）。
    # ⚠ 別プロセスで測る — 測りたいのは「プロセスが終わるまでの時間」。
    def test_host_can_exit_while_an_unstoppable_child_remains
      nap = unique_sleep
      script = <<~RUBY
        require 'ginseng'
        original = Process.method(:kill)
        Process.define_singleton_method(:kill) do |signal, *pids|
          raise Errno::EPERM if pids.any?(&:negative?)
          original.call(signal, *pids)
        end
        command = Ginseng::CommandLine.new(#{nap.split.inspect})
        command.instance_variable_set(:@logger, Class.new {def error(*) = nil}.new)
        begin
          command.exec(timeout: 0.3)
        rescue Timeout::Error
          nil
        end
      RUBY
      lib = File.expand_path('../lib', __dir__)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      host = Process.spawn(RbConfig.ruby, '-I', lib, '-e', script, out: File::NULL, err: File::NULL)
      waiter = Thread.new {Process.wait2(host).last}

      assert_not_nil(waiter.join(20), '子が終わるまでホストが終了しない')
      assert_predicate(waiter.value, :success?)
      # ⚠ 起動 ＋ 締切 0.3 ＋ 猶予 2 ＋ 見切り 1。子（30 秒）を待つと、ここを超える。
      assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15)
      assert_not_empty(running_now(nap))
    ensure
      Process.kill('KILL', host) if host && waiter&.alive?
      `pkill -KILL -f '^#{nap}$'` if nap
    end

    # いま居る番人の pid。
    def keepers
      return `pgrep -f '^/bin/sh -c trap .* echo; read _$'`.split
    end

    # 🔴 **番人が TERM を無視する準備を済ませる前に、TERM を送らない。**
    # ⚠⚠ `Process.spawn` が戻った時点では、シェルはまだ `trap` を実行していない。そこへ
    # グループ宛ての TERM が届くと番人が死に、**番号を確かめられなくなって KILL を送れない**
    # （TERM を無視する相手が残る）。実測: 起動から 2 ms 以内だと死ぬ。
    # ⚠ 番人の起動を 0.5 秒遅らせて、締切 0.2 秒を先に来させる。
    def test_exec_timeout_waits_for_the_keeper_before_term
      nap = unique_sleep
      events = []
      restore = trace_process_calls(events)
      spawn = Process.method(:spawn)
      Process.define_singleton_method(:spawn) do |*args, **options|
        args = [*args[0..1], "sleep 0.5; #{args[2]}"] if args[2].to_s.end_with?('read _')
        spawn.call(*args, **options)
      end
      @command.args = ['sh', '-c', "trap '' TERM; #{nap}; #{nap}"]

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 0.2)}

      assert_equal(['TERM', 'KILL'], events.select {|event| event.first == :kill}.map {|event| event[1]})
      assert_no_match(/still running/, error.message)
      assert_empty(running(nap))
    ensure
      Process.define_singleton_method(:spawn, spawn) if spawn
      restore&.call
    end

    # ⚠ コマンドが自分のグループへ TERM 以外を撒いても、番人は死なない（＝止められる）。
    def test_exec_timeout_survives_signals_the_command_sends_to_its_group
      nap = unique_sleep
      @command.args = ['sh', '-c', "trap '' INT TERM; kill -INT 0; #{nap}; #{nap}"]

      error = assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}

      assert_no_match(/still running/, error.message)
      assert_empty(running(nap))
    end

    # 🔴 **実行の最中にホストが fork しても、番人を残さない。**
    # ⚠⚠ fork した子は、番人の標準入力の書く側を継ぐ。こちらが閉じても番人に EOF が届かず、
    # fork した子が終わるまで番人が残る（長寿命の子を fork する常駐では溜まる）。
    def test_exec_with_timeout_leaves_no_keeper_behind_a_fork
      before = keepers
      @command.args = ['sh', '-c', 'sleep 0.6; echo ok']
      runner = Thread.new {@command.exec(timeout: 10)}
      sleep(0.2)
      bystander = fork {sleep(8) && exit!(0)}

      assert_equal(0, runner.value)
      remaining = []
      20.times do
        remaining = keepers - before
        break if remaining.empty?
        sleep(0.1)
      end

      assert_empty(remaining)
    ensure
      if bystander
        Process.kill('KILL', bystander)
        Process.wait(bystander)
      end
    end

    # 🔴 **呼び出し側が中断不可の区間に居ても、上限（締切 ＋ 3 秒）で戻る。**
    # ⚠⚠ 読み手のスレッドが中断不可を引き継ぐと `kill` が効かず、パイプを閉じる側が
    # 読み手を待って、**止められなかった相手が終わるまで戻らない**。
    def test_exec_timeout_returns_inside_an_uninterruptible_block
      nap = unique_sleep
      @command.args = ['sh', '-c', nap]
      original = deny_group_signals
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raise(Timeout::Error) do
        Thread.handle_interrupt(Object => :never) {@command.exec(timeout: 0.5)}
      end
      assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5.5)
    ensure
      Process.define_singleton_method(:kill, original) if original
      `pkill -KILL -f '^#{nap}$'` if nap
    end

    # ⚠ 番人を残さない。締切で抜けても、間に合っても、コマンドを起こせなくても。
    def test_exec_with_timeout_leaves_no_keeper_behind
      before = keepers
      @command.args = ['sh', '-c', 'echo ok']
      @command.exec(timeout: 10)
      @command.args = ['sh', '-c', unique_sleep]
      assert_raise(Timeout::Error) {@command.exec(timeout: 0.5)}
      @command.args = ['no-such-command-for-ginseng-test']
      assert_raise(Errno::ENOENT) {@command.exec(timeout: 10)}
      remaining = []
      20.times do
        remaining = keepers - before
        break if remaining.empty?
        sleep(0.1)
      end

      assert_empty(remaining)
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

    # グループ宛ての `Process.kill` と回収（`wait2`）を、番号つきで順に記録する。
    # 元へ戻す手続きを返す。
    def trace_process_calls(events)
      originals = [:kill, :wait2].to_h {|name| [name, Process.method(name)]}
      Process.define_singleton_method(:kill) do |signal, *pids|
        pids.select(&:negative?).each {|pid| events.push([:kill, signal, -pid])} if signal != 0
        originals[:kill].call(signal, *pids)
      end
      Process.define_singleton_method(:wait2) do |pid, *args|
        result = originals[:wait2].call(pid, *args)
        events.push([:reaped, pid]) if result
        result
      end
      return -> {originals.each {|name, impl| Process.define_singleton_method(name, impl)}}
    end

    # 🔴 **グループの番号を手放したあとは、そこへ送っていないこと。**
    # ⚠ 手放す = その番号の持ち主（番人）を回収した・KILL した。
    def assert_no_signal_after_release(events, message = nil)
      events.each_with_index do |(kind, signal, group), index|
        next unless kind == :kill
        earlier = events[0...index]
        released = earlier.include?([:reaped, group])
        killed = earlier.include?([:kill, 'KILL', group])

        assert_false(released || killed, "#{message}: #{signal} after release in #{events.inspect}")
      end
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
