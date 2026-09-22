# frozen_string_literal: true

module Ginseng
  # デーモンの停止・起動判断 (#509 / #510)。
  #
  # ⚠ **芯は「消したのに生きている」状態を作らないこと。**`Errno::EPERM` のときに
  # pid ファイルだけ消えると、プロセスは生きたまま残り、次の start が 2 本目を
  # 立てて 1 本目がどの pid ファイルからも辿れない孤児になる。
  class DaemonTest < TestCase
    # シグナル送信だけ差し替えたデーモン。⚠ 他人のプロセスへ実際に TERM を送る
    # テストは書けないので、継ぎ目 (send_signal) で例外を注入する。
    class Stub < Daemon
      attr_reader :signals, :logs

      def initialize(opts = {})
        super
        @signals = []
        @error = opts[:error]
        # ⚠⚠ **ログは「出たこと」を測る対象**（リリース前レビューの赤 2 回とも
        # 「起動しなかったのに 1 行も残らない」形だった）。syslog へは出さない。
        @logs = []
        @logger = Recorder.new(@logs)
      end

      # 出力先ではなく記録だけする logger。⚠ 上流が渡す Hash をそのまま持つ。
      class Recorder
        def initialize(logs)
          @logs = logs
        end

        [:error, :warn, :info, :debug, :fatal].each do |severity|
          define_method(severity) do |message = nil|
            @logs.push([severity, message])
            return true
          end
        end
      end

      def command
        return 'true'
      end

      private

      def send_signal(signal, pid)
        @signals.push([signal, pid])
        raise @error if @error
      end
    end

    # ⚠ **`exec` はプロセスを置き換えるので、テストからは呼べない。**
    # 🔴 測りたいのは**失敗したときに何が残るか**なので、そちらだけ差し替える。
    class FailingStub < Stub
      def start(_args = [])
        raise Errno::ENOENT, 'bundle'
      end
    end

    def setup
      @dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(@dir, 'tmp/pids'))
    end

    def teardown
      super
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    def test_alive_state_without_pid_file
      assert_equal(:dead, create.alive_state)
      assert_false(create.alive?)
    end

    def test_alive_state_with_own_pid
      daemon = create(pid: Process.pid)

      assert_equal(:alive, daemon.alive_state)
      assert_predicate(daemon, :alive?)
    end

    # ⚠ pid ファイルが古くてプロセスが居なければ :dead。
    def test_alive_state_with_stale_pid
      daemon = create(pid: unused_pid)

      assert_equal(:dead, daemon.alive_state)
    end

    # ⚠⚠ **`alive_state` は pid ファイルを 1 回だけ読み、その番号を上書き点へ渡す
    # (#638)。** 🔴 利用側（`makoto2`）は身元（`/proc/<pid>/cmdline`）を足すために
    # `super` のあと `pid` を読み直していた — ⚠ **2 回の読みの間に書き換わると、
    # 「A の生死」に「B の身元」を掛けた答え**になる。
    def test_alive_state_hands_the_number_it_read_to_the_override
      daemon = create(pid: Process.pid)
      seen = []
      reads = 0
      daemon.define_singleton_method(:alive_state_of) do |found|
        seen.push(found)
        next super(found)
      end
      daemon.define_singleton_method(:pid) do
        reads += 1
        next super()
      end

      assert_equal(:alive, daemon.alive_state)
      assert_equal([Process.pid], seen, '読んだ番号がそのまま渡ること')
      assert_equal(1, reads, 'pid ファイルを読み直さないこと')
    end

    # ⚠ **番号が取れなかったときの答えは `alive_state` が決める (#638)。**
    # 🔴 上書き点に nil を渡すと、利用側が毎回「番号の無い場合」を書くことになり、
    # ⚠⚠ そこで :dead に倒すと**読めないだけの pid ファイルが「起動していない」に化ける**。
    def test_alive_state_of_is_not_called_without_a_number
      daemon = create
      seen = []
      daemon.define_singleton_method(:alive_state_of) do |found|
        seen.push(found)
        next :alive
      end

      assert_equal(:dead, daemon.alive_state)
      assert_empty(seen, '番号が無いときは上書き点を通らないこと')
    end

    # 🔴 **読めないときも上書き点を通らないこと (#638)。** ⚠⚠ ここで通すと、利用側の
    # 身元チェックが「番号が無い」を :dead と答え、**生きている常駐の pid ファイルを
    # 奪いにいける**（#635 で上流に寄せた判断が戻る）。
    def test_alive_state_of_is_not_called_when_the_pid_file_cannot_be_read
      daemon = create(pid: Process.pid)
      seen = []
      daemon.define_singleton_method(:alive_state_of) do |found|
        seen.push(found)
        next :alive
      end
      original = stub_read_error(daemon, Errno::EIO)

      assert_equal(:unknown, daemon.alive_state)
      assert_empty(seen, '読めないときは上書き点を通らないこと')
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **判断の入口は `alive_state` を通すこと (#638)。** ⚠⚠ 入口が
    # `alive_state_of` を直に呼ぶ形へ畳まれると、**上書きした身元チェックが黙って
    # 外れる** — 生きてはいるが「うちの常駐ではない」pid を `status` が running と言う。
    def test_run_status_honours_the_override
      daemon = create(pid: Process.pid)
      daemon.define_singleton_method(:alive_state_of) {|_found| :dead}

      output = capture_stdout {daemon.send(:run_status)}

      assert_match(/is not running/, output)
      assert_not_match(/is running/, output, '身元の否定が届くこと')
    end

    # ⚠ **起動の門にも届くこと (#638)。** 🔴 pid が再利用されているだけなら、
    # 利用側は起動させたい（上流だけ見ると :alive で永久に拒む）。
    def test_abort_if_running_honours_the_override
      daemon = create(pid: Process.pid)
      daemon.define_singleton_method(:alive_state_of) {|_found| :dead}

      assert_nothing_raised(SystemExit) {daemon.send(:abort_if_running!)}
    end

    # 🔴🔴 **`exec` が落ちても成功と同じ 1 行しか出ていなかった (#637)。**
    #
    # ⚠⚠ `start` は `info` を出してから `exec` するので、**コマンドのパスが変わった**
    # ときでもログは成功時と同一だった。🔴 `restart` の子は stderr が `/dev/null`。
    def test_run_start_reports_a_failed_exec
      daemon = FailingStub.new({application: 'GinsengDaemonTest', working_dir: @dir})
      FileUtils.rm_f(daemon.pid_file)

      output = capture_stdout do
        capture_stderr do
          assert_raise(SystemExit) {daemon.send(:run_start)}
        end
      end

      assert_equal('start failed', daemon.logs.last.last[:reason])
      assert_equal('Errno::ENOENT', daemon.logs.last.last[:error])
      assert_not_empty(output)
    end

    # ⚠ **起動できていない pid ファイルを残さない (#637)。**
    def test_run_start_removes_the_pid_file_after_a_failed_exec
      daemon = FailingStub.new({application: 'GinsengDaemonTest', working_dir: @dir})
      FileUtils.rm_f(daemon.pid_file)

      capture_stdout do
        capture_stderr do
          assert_raise(SystemExit) {daemon.send(:run_start)}
        end
      end

      assert_false(File.exist?(daemon.pid_file))
    end

    # 🔴 **`ESRCH` だけ logger を通っていなかった (#637)。**
    # ⚠⚠ **pid ファイルが在るのに中のプロセスが消えている**は、運用上
    # いちばん知りたい状態。
    def test_run_stop_logs_a_missing_process
      daemon = create(pid: Process.pid, error: Errno::ESRCH)

      capture_stderr {daemon.send(:run_stop)}

      assert_include(daemon.logs.map {|_severity, message| message[:reason]},
        'process was not running')
    end

    # 🔴🔴 **「在るが pid ファイルとして読めるものではない」を「無い」と言わない (#637)。**
    def test_run_stop_reports_an_invalid_pid_file
      daemon = create
      File.write(daemon.pid_file, "ごみ\n")

      output = capture_stderr do
        assert_raise(SystemExit) {daemon.send(:run_stop)}
      end

      assert_match(/is not a valid PID file/, output)
      assert_not_match(/not found/, output, '在るのに「無い」と言わないこと')
      assert_equal('pid file invalid', daemon.logs.last.last[:reason])
    end

    # ⚠ `status` も同じ第 3 の状態を言い分ける (#637)。
    def test_run_status_reports_an_invalid_pid_file
      daemon = create
      File.write(daemon.pid_file, "ごみ\n")

      output = capture_stdout {daemon.send(:run_status)}

      assert_match(/is not a valid PID file/, output)
      assert_not_match(/is not running/, output)
    end

    # 🔴🔴 **「番号は読めたが死んでいる」を「妥当でない」と言わない (#637 の回帰)。**
    #
    # ⚠⚠ ふつうの停止・異常終了のあとは**必ずこの形**（pid ファイルは在り、中の番号は
    # 正しく、プロセスだけ居ない）になる。🔴 ここを `is not a valid PID file` と言うと
    # **いちばん多い状態が毎回「壊れている」に見え**、本物のゴミと区別できなくなる。
    def test_run_status_does_not_call_a_stale_pid_file_invalid
      daemon = create(pid: unused_pid)

      output = capture_stdout {daemon.send(:run_status)}

      assert_match(/is not running/, output)
      assert_not_match(/is not a valid PID file/, output, '古いだけのものを壊れていると言わないこと')
      assert_match(/stale/, output, '置かれたままであることは伝えること')
    end

    # ⚠ `start` も同じ (#637)。🔴 従来は `Could not acquire`（`error: nil`）だけだった。
    def test_write_pid_reports_an_invalid_pid_file
      daemon = create
      File.mkfifo(daemon.pid_file)

      Timeout.timeout(5) do
        assert_raise(SystemExit) {daemon.send(:write_pid)}
      end

      assert_equal('pid file invalid', daemon.logs.last.last[:reason])
    end

    # 🔴🔴 **`remove_pid` の失敗が完全に無音だった (#637)。**
    # ⚠⚠ stdout / stderr / ログすべて空で exit 0 — 「stop は成功」に見えて pid
    # ファイルが残る。🔴 その間に pid が再利用されると、`already running (PID N)` が
    # 無関係のプロセスを指す。
    def test_run_stop_logs_a_pid_file_left_behind
      daemon = create(pid: Process.pid)
      original = stub_read_error(daemon, Errno::EIO, on: 2)

      capture_stderr {daemon.send(:run_stop)}

      assert_include(daemon.logs.map {|_severity, message| message[:message]},
        'pid file left behind')
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **もう無いなら黙る (#637 Codex P2)。**
    #
    # ⚠⚠ 相手の trap が先に自分の pid ファイルを消すので、止める側が見るときには
    # 無くなっていることがある — 🔴 **これは正常な停止なので、鳴ると誤報になる**。
    def test_run_stop_is_quiet_when_the_pid_file_is_already_gone
      daemon = create(pid: Process.pid)
      daemon.define_singleton_method(:send_signal) do |signal, pid|
        FileUtils.rm_f(pid_file)
        next super(signal, pid)
      end

      capture_stderr {daemon.send(:run_stop)}

      assert_not_include(daemon.logs.map {|_severity, message| message[:message]},
        'pid file left behind')
    end

    # ⚠ **後継が取り直した形では黙る (#532 / #637)。**
    # 🔴🔴 ここで警報を出すと、**正常な交代のたびに鳴る**。
    def test_run_stop_is_quiet_when_a_successor_took_over
      daemon = create(pid: Process.pid)
      successor = Process.ppid
      daemon.define_singleton_method(:send_signal) do |signal, pid|
        File.write(pid_file, successor.to_s)
        next super(signal, pid)
      end

      capture_stderr {daemon.send(:run_stop)}

      assert_not_include(daemon.logs.map {|_severity, message| message[:message]},
        'pid file left behind')
      assert_equal(successor, daemon.pid, '後継の pid ファイルを消さないこと')
    end

    # 🔴 **通常ファイルでないものを黙って置き換えない (#637 / #643)。**
    #
    # ⚠ `rename` は名前を差し替えるだけなので壊れはしないが、この位置に FIFO や
    # ディレクトリが置かれる正当な形が無い。🔴 無音だと、最後に出るのは
    # `Could not acquire PID file` だけになる。
    def test_write_pid_refuses_a_non_regular_pid_file
      daemon = create
      File.mkfifo(daemon.pid_file)

      output = capture_stderr do
        Timeout.timeout(5) {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      end

      assert_match(/exists but is not a valid PID file \(fifo\)/, output)
      # ⚠ **1 行だけ残す**（warn と error の二重にしない。種類は本文に入れる）。
      assert_equal([[:error, 'pid file invalid']],
        daemon.logs.map {|severity, message| [severity, message[:reason]]})
      assert_equal('fifo', File.lstat(daemon.pid_file).ftype, '置き換えないこと')

      File.unlink(daemon.pid_file)
      Dir.mkdir(daemon.pid_file)

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_true(File.directory?(daemon.pid_file))
    end

    # ⚠ **番号が無いときに "exists" と言わない (#637)。**
    # 🔴 2 つの読み取りの間に現れて消えた形もここへ来る。
    def test_run_status_does_not_claim_a_missing_pid_file_exists
      daemon = create
      daemon.define_singleton_method(:alive_state) {:unknown}

      output = capture_stdout {daemon.send(:run_status)}

      assert_match(/state is unknown/, output)
      assert_not_match(/exists/, output)
    end

    # 🔴🔴 **子の起動失敗を exit 0 で返さない (#630)。**
    #
    # ⚠⚠ 子は stdout / stderr を `/dev/null` へ付け替えているので、**親が見なければ
    # 監視・デプロイのスクリプトからは「再起動は成功」に見える**。
    #
    # 🔴🔴 **このテストが通っているのは `run_start` まで届いたからではない
    # （リリース前レビューの黄）。** ⚠⚠ `capture_stderr` が `$stderr` を `StringIO` へ
    # 差し替えるので、子の `$stderr.reopen(File::NULL, 'w')` が `Errno::EACCES` で落ちる。
    # ⚠ **固定しているのは「子が非ゼロで終われば親が `not restarted` を出して exit 1
    # する」だけ** — `write_pid` / `exec` / 失敗時の後始末は restart 経路では通らない。
    def test_run_restart_reports_a_child_that_did_not_stay_up
      daemon = create

      output = capture_stderr do
        assert_raise(SystemExit) {daemon.send(:run_restart)}
      end

      assert_match(/did not stay up/, output)
      assert_equal('not restarted', daemon.logs.last.last[:message])
      assert_equal('child exited', daemon.logs.last.last[:reason])
    end

    # ⚠ **生きていれば猶予を使い切って真を返す (#630)。**
    # 🔴 こちらを本番の猶予（3 秒）で測るとテストがその分止まるので、**短く渡す**。
    def test_await_child_waits_out_the_grace_period
      daemon = create
      child = fork {sleep 5}

      begin
        assert_true(daemon.send(:await_child, child, 0.3))
      ensure
        Process.kill('TERM', child)
        Process.waitpid(child)
      end
    end

    # 🔴🔴 **猶予の終わり際に落ちた子を見落とさない (#630 Codex P2)。**
    #
    # ⚠⚠ 最後の `sleep` のあいだに落ちると、ループの条件が偽になって
    # **見ないまま成功と答えてしまう**。⚠ 猶予 0 秒（ループを 1 回も回さない）で測る。
    def test_await_child_checks_once_more_at_the_deadline
      daemon = create
      child = fork {exit 1}
      sleep 0.5

      assert_false(daemon.send(:await_child, child, 0), '締め切りでもう一度見ること')
    end

    # ⚠ **落ちたことを見たら即座に戻る**（猶予を使い切らない）。
    def test_await_child_returns_false_as_soon_as_the_child_exits
      daemon = create
      child = fork {exit 1}
      started = Time.now

      assert_false(daemon.send(:await_child, child, 5))
      assert_operator(Time.now - started, :<, 5, '猶予を使い切らないこと')
    end

    def test_run_stop_sends_term_and_removes_pid
      daemon = create(pid: Process.pid)
      daemon.send(:run_stop)

      assert_equal([['TERM', Process.pid]], daemon.signals)
      assert_false(File.exist?(daemon.pid_file))
    end

    # 既に居ないなら pid ファイルは消してよい（従来どおり）。
    def test_run_stop_removes_pid_when_process_is_gone
      daemon = create(pid: Process.pid, error: Errno::ESRCH)
      daemon.send(:run_stop)

      assert_false(File.exist?(daemon.pid_file))
    end

    # ⚠⚠ **本件の芯** (#509)。触れなかったときに pid ファイルを消さない。
    # 消すと生きたままのプロセスが辿れなくなり、次の start が 2 本目を立てる。
    def test_run_stop_keeps_pid_on_eperm
      daemon = create(pid: Process.pid, error: Errno::EPERM)

      assert_raise(SystemExit) {daemon.send(:run_stop)}
      # ⚠ assert_path_exists は Minitest のもので test-unit には無い。
      # cop は ginseng-style の正本で切ってあるので、行内の disable は要らない (#535)。
      assert(File.exist?(daemon.pid_file))
      assert_equal(Process.pid, daemon.pid)
    end

    def test_run_stop_exits_without_pid_file
      assert_raise(SystemExit) {create.send(:run_stop)}
    end

    # 🔴 **後継の pid ファイルを消さないこと (#532)。**
    #
    # 相手が TERM を先に処理して自分の trap で pid ファイルを消し、supervisor が
    # 後継を起動して**新しい pid を書いた**あとに、こちらの remove_pid が走ると、
    # **後継の pid ファイルが消える**。⚠⚠ 後継はどの pid ファイルからも辿れなく
    # なり、次の start が 2 本目を立てる（#509 と同じ結末の、別のレース）。
    def test_run_stop_keeps_pid_of_successor
      daemon = create(pid: unused_pid)
      successor = Process.pid
      # send_signal の中で「相手が消して後継が書き直した」状態を作る。
      daemon.define_singleton_method(:send_signal) do |_signal, _pid|
        File.write(pid_file, successor.to_s)
      end

      daemon.send(:run_stop)

      assert_equal(successor, daemon.pid, '後継の pid ファイルが残ること')
    end

    # 自分が知っている pid のままなら、従来どおり消す。
    def test_run_stop_removes_own_pid
      daemon = create(pid: unused_pid)

      daemon.send(:run_stop)

      assert_nil(daemon.pid)
      assert_path_not_exist(daemon.pid_file)
    end

    # ⚠⚠ **読む直前に消えても例外にしない (#561)。** 相手の trap が消した直後に
    # `File.read` すると `Errno::ENOENT` になり、🔴 `run_restart` が `run_stop` の
    # 途中で抜けて**止めただけで後継を fork しない**。
    def test_pid_tolerates_concurrent_removal
      daemon = create(pid: unused_pid)
      # 開こうとした瞬間には消えている状況を作る。
      original = stub_read_error(daemon, Errno::ENOENT)

      assert_nil(daemon.pid)
      # ⚠ 「無い」なので :dead。**読めなかった（:unknown）と混ぜない。**
      assert_equal(:dead, daemon.alive_state)
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # ⚠⚠ **本件の芯 (#622)。** pid ファイルが既に在って持ち主が生きているなら、
    # `write_pid` は**上書きせずに終了する**。🔴 上書きすると、先に起動した 1 本が
    # どの pid ファイルからも辿れない孤児になる（start 同士のレースの帰結）。
    def test_write_pid_refuses_when_owner_is_alive
      owner = Process.ppid
      daemon = create(pid: owner)

      assert_raise(SystemExit) {daemon.send(:write_pid)}
      assert_equal(owner, daemon.pid, '先に取った側の pid が残ること')
    end

    # ⚠ **:unknown でも取らない** (#510)。触れないだけで生きている可能性がある。
    # ⚠⚠ **中身を書き替えないこと**まで測る — 奪うと次の start が 2 本目を立てる。
    def test_write_pid_refuses_when_owner_is_unknown
      stale = unused_pid
      daemon = create(pid: stale)
      daemon.define_singleton_method(:alive_state) {:unknown}

      assert_raise(SystemExit) {daemon.send(:write_pid)}
      assert_equal(stale, daemon.pid, 'pid ファイルを奪わないこと')
    end

    # ⚠⚠ **異常終了で残った pid ファイルは置き換えて起動する (#622 / #643)。**
    # 死んでいると断定できた pid ファイルは、一時ファイルの `rename` で置き換える。
    # unlink してから作り直す形は取らない（→ `test_write_pid_never_unlinks`）。
    def test_write_pid_reclaims_dead_pid_file
      daemon = create(pid: unused_pid)

      # ⚠⚠ **`SystemExit` は受けること** — 素で投げさせるとスイート自体が途中で
      # 終わり、🔴 **test-unit は「100% passed」のまま件数だけ減らす**（実測）。
      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # ⚠⚠ **自分が既に取っている pid ファイルで自分を殺さないこと。**
    # 2 度目の呼び出しは自分の pid を読む。`observed_pid == Process.pid` の早期 return が
    # 無いと、`abort_if_running!` が自分を :alive と見て「already running」で終わる。
    def test_write_pid_is_idempotent_for_the_owner
      daemon = create
      daemon.send(:write_pid)

      # 🔴🔴 **`assert_nothing_raised` で受けること。** ここが `exit 1` に倒れると
      # ⚠⚠ **SystemExit がスイート自体を打ち切る** — test-unit は**そこまでの件数で
      # 「100% passed」と表示して緑で終わる**（実測: 17 件が 12 件になり、失敗は 0）。
      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    def test_write_pid_creates_pid_file
      daemon = create

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # 🔴 **奪ってよいのは「自分が死んでいると判断した pid のまま」のときだけ (#532)。**
    # 判断してから奪うまでの間に別の start が取り直していたら、それは他人の pid
    # ファイルで、⚠⚠ **書き替えればその 1 本を孤児にする**。
    def test_write_pid_keeps_pid_file_taken_by_another_start
      daemon = create(pid: unused_pid)
      successor = Process.ppid
      states = [:dead, :alive]
      # alive_state を見ている隙に「別の start が取り直した」状態を作る。
      daemon.define_singleton_method(:alive_state) do
        File.write(pid_file, successor.to_s) if states.first == :dead
        next states.shift || :alive
      end

      assert_raise(SystemExit) {daemon.send(:write_pid)}
      assert_equal(successor, daemon.pid, '後から取った側の pid ファイルが残ること')
    end

    # ⚠⚠ **奪えるのはロックを取れた 1 本だけ (#622 / #643)。**
    # 別の start が判断している間は置き換えずに諦める。
    def test_write_pid_gives_up_while_another_start_holds_the_lock
      stale = unused_pid
      daemon = create(pid: stale)
      File.open(daemon.pid_lock_file, File::RDONLY | File::CREAT) do |holder|
        holder.flock(File::LOCK_EX)

        output = capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}

        assert_match(/Could not acquire PID file/, output)
        assert_equal(stale, daemon.pid, '中身を書き替えないこと')
      end
    end

    # 🔴🔴 **判断のあいだに中身が変わったら置き換えない (#643)。**
    #
    # ⚠ ロックを取らない書き手が居る（移行期の旧版の start・`remove_pid`）。
    # ⚠⚠ **pid として読めない中身の経路**を測る — こちらは `alive_state` を通らないので、
    # `test_write_pid_keeps_pid_file_taken_by_another_start` では押さえられない。
    def test_write_pid_keeps_a_pid_file_written_while_deciding
      daemon = create
      File.write(daemon.pid_file, '')
      successor = Process.ppid
      reads = 0
      daemon.define_singleton_method(:read_pid_file) do
        found = super()
        reads += 1
        File.write(pid_file, successor.to_s) if reads == 1
        next found
      end

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_equal(successor, daemon.pid, '後から書かれた pid を残すこと')
    end

    # 🔴🔴 **見捨てられた空の pid ファイルから復帰できること (#622 Codex P1)。**
    #
    # 1.25.0 からは `rename` で置くので自分では空を作らないが、旧版（`O_EXCL` で作って
    # から書いていた）や外部の書き手が残しうる。⚠⚠ **ここを拒むと、失敗した 1 回の
    # 起動が恒久的な起動不能に化ける**（手で消すまで直らない）。
    #
    # ⚠ 置き換えてよいのは、判断と置き換えをロックの中で行い、置き換える直前に中身が
    # 変わっていないことを確かめているから（→ `test_write_pid_keeps_a_pid_file_written_while_deciding`）。
    def test_write_pid_reclaims_an_abandoned_empty_pid_file
      daemon = create
      File.write(daemon.pid_file, '')

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # ⚠⚠ **一時ファイルを作れないときも、例外のまま抜けないこと。** 🔴 例外のまま
    # 抜けると backtrace だけが出て、運用者には理由が伝わらない。
    # ⚠ 権限そのものではなく `Errno::EACCES` の扱いを測る（CI は root で回るので、
    # chmod では再現できない）。🔴🔴 **ここで塞げるのは「作れない」側だけ** —
    # **読めない側は `test_pid_tolerates_an_unreadable_pid_file` で別に測る**。
    def test_write_pid_gives_up_cleanly_when_the_temp_file_cannot_be_created
      stale = unused_pid
      daemon = create(pid: stale)
      original = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, &block|
        raise Errno::EACCES, path if args.first == Daemon::PidFile::PID_TEMP_OPEN_FLAGS
        next original.call(path, *args, &block)
      end

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_equal(stale, daemon.pid, 'pid ファイルは元のまま')
      # ⚠ **errno まで残ること**（理由だけだと、権限か満杯かを切り分けられない）。
      assert_equal([[:error, 'pid file write failed', 'Errno::EACCES']],
        daemon.logs.map {|severity, message| [severity, message[:reason], message[:error]]})
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **start の経路で `rm_f` を使わないこと (#622 Codex P1)。**
    #
    # 「消して作り直す」だと、⚠⚠ **同じ stale を見た 2 本が両方 `remove_pid` の
    # 検査を通る** — 片方が消して作った直後に、もう片方の `rm_f` が**その新しい
    # pid ファイルを消す**。⚠ 置き換えは `rename` 1 回で行い、名前が無い瞬間を作らない
    # (#643)。
    def test_write_pid_never_unlinks
      daemon = create(pid: unused_pid)
      removed = []
      original = FileUtils.method(:rm_f)
      FileUtils.define_singleton_method(:rm_f) do |*args|
        removed.push(args.first)
        next original.call(*args)
      end

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal([], removed, 'pid ファイルを消さずに奪うこと')
      assert_equal(Process.pid, daemon.pid)
    ensure
      FileUtils.define_singleton_method(:rm_f, original) if original
    end

    # 🔴🔴 **pid として読めない中身は「起動していない」と答えること (#627)。**
    #
    # ⚠⚠ **`to_i` の結果をそのまま返すと空も壊れた中身も `0` になる。** `0` は truthy な
    # うえ `Process.kill(0, 0)` は自分のプロセスグループ宛てなので成功するため、
    # 🔴 `alive_state` が `:alive` と答えていた。
    def test_pid_rejects_a_broken_pid_file
      daemon = create

      # ⚠ **どの門で落ちるかで分けて並べる。** 3 つの上限（量・形・番号）は理由が
      # 別なので、まとめて 1 本の配列にすると何を測っているのか読めなくなる。
      broken = {
        # 🔴 **`'123abc'.to_i` は `123`。** 先頭が数字なら壊れたファイルでも通り、
        # ⚠⚠ **`run_stop` がその番号の無関係なプロセスへ `TERM` を送る**（Codex P1）。
        # 🔴 **`Integer(value, 10)` でもまだ足りない** — Ruby は**アンダースコアを
        # 桁区切りとして受け付ける**ので `'12_34'` が `1234` になる（Codex P1・2 巡目）。
        形: ['', "\n", 'not a pid', '-1', '123abc', '12 34', "1\n2", '0x10', '12_34',
          '+123', '１２３'],
        # ⚠ `0` は「自分のプロセスグループ」を指すので pid ではない (#627)。
        下端: ['0', "0\n"],
        # 🔴🔴 **`9999999999` は 10 桁だが `pid_t`（32bit 符号付き）の範囲外**（Codex P2）。
        # `Process.kill` が `RangeError` を上げ、`alive_state` が `:unknown` に丸めるので、
        # ⚠⚠ **通してしまうと起動を永久に拒み、奪って復帰する機会も来ない**。
        上端: ['2147483648', '9999999999'],
      }
      broken.values.flatten.each do |content|
        File.write(daemon.pid_file, content)

        assert_nil(daemon.pid, "#{content.inspect} は pid として読めない")
        assert_equal(:dead, daemon.alive_state, "#{content.inspect} で :alive と答えない")
      end
    end

    # 🔴🔴 **読めない pid ファイルを「無い」と答えないこと (#627 Codex P2)。**
    #
    # ⚠⚠ **:dead に倒すと `run_status` が「動いていない」と嘘をつき、`run_restart` が
    # 停止を飛ばす。** 別ユーザーの pid ファイルは**触れないだけで生きている可能性が
    # ある**ので :unknown（#510 と同じ理由）。
    # ⚠ 権限そのものは測れない（CI は root で回る）ので、読めない状態を注入する。
    def test_alive_state_is_unknown_for_an_unreadable_pid_file
      daemon = create(pid: unused_pid)
      original = stub_read_error(daemon, Errno::EACCES)

      assert_equal(:unknown, daemon.alive_state)
      assert_false(daemon.alive?)
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **`run_start` の門は `abort_if_running!` (リリース前レビュー)。**
    # ⚠⚠ **ここで止まると `write_pid` の丁寧な扱いは届かない** — 見捨てられた
    # pid ファイルからの復帰は、この門が通って初めて実運用に効く。
    def test_abort_if_running_passes_for_a_broken_pid_file
      daemon = create

      ['', 'not a pid'].each do |content|
        File.write(daemon.pid_file, content)

        assert_nothing_raised(SystemExit) {daemon.send(:abort_if_running!)}
      end
    end

    # 🔴🔴 **プロセスグループ全体へ TERM を送らないこと (#627)。**
    # `Process.kill('TERM', 0)` は**呼び出し元のプロセスグループ全体**に届く。
    def test_run_stop_does_not_signal_the_process_group_for_a_broken_pid_file
      daemon = create
      File.write(daemon.pid_file, '')

      assert_raise(SystemExit) {daemon.send(:run_stop)}
      assert_equal([], daemon.signals, 'pid として読めない中身にシグナルを送らないこと')
    end

    # ⚠⚠ **読めない pid ファイルで例外のまま抜けないこと（リリース前レビュー）。**
    # 🔴 `File.read` は `File.open` を通らないので、開く側の rescue では塞げない。
    def test_pid_tolerates_an_unreadable_pid_file
      daemon = create(pid: unused_pid)
      original = stub_read_error(daemon, Errno::EACCES)

      assert_nil(daemon.pid)
      # ⚠ 触れないので取得もできない。**起動しないが、backtrace では終わらない。**
      assert_raise(SystemExit) {daemon.send(:write_pid)}
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **上限で切った先頭が「読める pid」に化けないこと (#629 Codex P1)。**
    #
    # `File.read(path, n)` は EOF に届いたかを教えないので、⚠⚠ **`'123' ＋ 空白 ＋
    # ゴミ` を切って `strip` すると `123` として通る** — その番号は無関係なプロセスで
    # ありうる（`run_stop` がそちらへ `TERM` を送る）。
    def test_pid_rejects_an_oversized_file_whose_head_looks_like_a_pid
      daemon = create
      File.write(daemon.pid_file, "#{Process.ppid}#{' ' * 200}junk")

      assert_nil(daemon.pid)
      # ⚠ 読めないだけで、奪って復帰はできる。
      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # 🔴🔴 **読めない理由は権限だけではない (#633 Codex P2)。**
    #
    # `EIO` のような読み取り失敗を `:dead` に倒すと、⚠⚠ **`run_status` が「動いて
    # いない」と嘘をつき、`run_restart` が停止を飛ばす** — pid ファイルが生きている
    # プロセスを指している可能性があるのに。
    def test_alive_state_is_unknown_when_the_pid_file_cannot_be_read
      daemon = create(pid: unused_pid)
      # ⚠ **1 回だけ失敗する**（一過性の EIO）。🔴 読み直して確かめる実装だと、
      # 2 回目が成功して :dead に落ちる — **読めなかった事実を捨てている**。
      original = stub_read_error(daemon, Errno::EIO, once: true)

      assert_equal(:unknown, daemon.alive_state)
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **起動しない・止められないときは、必ず logger に 1 行残ること (#635)。**
    #
    # ⚠⚠ **stderr は当てにできない** — `run_restart` は fork した子の stderr を
    # `File::NULL` へ付け替え、利用側の起動スクリプトも非 tty では捨てる。
    # 🔴 リリース前レビューは**同じ形の赤を 2 回**出している（1 回目は
    # 当時の `create_pid_file`（#643 で廃止）、2 回目は `run_stop`）。**出口ごとに測る。**
    def test_every_refusal_is_logged
      # ⚠ 状態はケースごとに作る（`create` は同じ working_dir を使うので持ち越す）。
      refusals = {
        'start: 既に動いている' => [Process.ppid, :write_pid],
        'stop: pid ファイルが無い' => [nil, :run_stop],
      }

      refusals.each do |name, (pid, method)|
        daemon = create(pid:)
        assert_raise(SystemExit, name) {daemon.send(method)}
        assert_equal([:error], daemon.logs.map(&:first), name)
        assert(daemon.logs.first.last.key?(:reason), "#{name}: 理由が入っていること")
      end
    end

    # 🔴🔴 **読めない pid ファイルで `restart` が無音にならないこと (#635)。**
    #
    # ⚠⚠ **`run_restart` は `alive_state` が :dead でなければ `run_stop` を通る。**
    # 読めないと :unknown なので必ず通り、そこが黙って `exit 1` していた
    # （⚠ しかも「PID file not found」は**嘘** — ファイルはそこに在る）。
    def test_run_stop_logs_when_the_pid_file_cannot_be_read
      daemon = create(pid: unused_pid)
      original = stub_read_error(daemon, Errno::EACCES)

      assert_equal(:unknown, daemon.alive_state, 'restart はここで run_stop を通る')
      assert_raise(SystemExit) {daemon.send(:run_stop)}
      assert_equal([:error], daemon.logs.map(&:first))
      assert_equal('pid file unreadable', daemon.logs.first.last[:reason])
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **拒む理由を組み立てる途中で、読み直して errno を消さないこと (#635 Codex P2)。**
    #
    # ⚠ `pid_label` は `pid` を呼ぶので pid ファイルを読み直す。一過性の失敗だと
    # ⚠⚠ **2 回目が成功して `error: nil` になり、しかも「PID 123 could not be read」と
    # いう矛盾したメッセージになる** — 足したばかりの errno の記録が消える。
    def test_refusal_keeps_the_read_error
      daemon = create(pid: unused_pid)
      original = stub_read_error(daemon, Errno::EIO, once: true)

      assert_raise(SystemExit) {daemon.send(:abort_if_running!)}
      assert_equal('Errno::EIO', daemon.logs.first.last[:error], '読めなかった理由が残ること')
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # ⚠⚠ **`pid_label` は `v1.23.6` で公開した形。引数なしでも呼べること (#635 Codex P2)。**
    # 🔴 必須にすると、上書きしている利用側が `ArgumentError` で落ちる。
    def test_pid_label_is_callable_without_an_argument
      daemon = create(pid: unused_pid)

      assert_equal("PID #{daemon.pid}", daemon.send(:pid_label))
      assert_match(/PID file/, create.send(:pid_label))
    end

    # 🔴🔴 **検証の読み取り自身が失敗しても、正しく報告すること (#635 Codex P2・7 巡目)。**
    # ⚠⚠ 失敗すると `nil` が返るので、**「変わった」にも「変わっていない」にも化ける**。
    def test_run_status_reports_a_failed_verification_read
      daemon = create(pid: unused_pid)
      original = stub_read_error(daemon, Errno::EIO, on: 3)

      output = capture_stdout {daemon.send(:run_status)}

      assert_match(/could not be read/, output)
      assert_not_match(/changed while checking/, output)
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **起動を拒むときも、変わった番号を名乗らないこと (#635 Codex P2・7 巡目)。**
    # ⚠ 拒むこと自体は変わらないが、**ログに残る番号が別のプロセスのもの**になる。
    def test_abort_if_running_does_not_name_a_changed_pid
      daemon = create(pid: unused_pid)
      successor = Process.ppid
      daemon.define_singleton_method(:alive_state) do
        File.write(pid_file, successor.to_s)
        next :alive
      end

      output = capture_stderr do
        assert_raise(SystemExit) {daemon.send(:abort_if_running!)}
      end

      assert_not_match(/PID \d/, output, '別のプロセスの番号を名乗らないこと')
      assert_match(/PID file/, output)
    end

    # 🔴🔴 **検査のあいだに pid ファイルが変わったら、番号入りで報告しないこと
    # (#635 Codex P2・6 巡目)。**
    #
    # ⚠⚠ 別の start が死んだ pid を奪って自分のものを書くと、`alive_state` は新しい方を
    # 見て `:alive`、番号は古い方になる — 🔴 **死んだ番号を「動いている」と報告する**。
    def test_run_status_detects_a_pid_change_while_checking
      daemon = create(pid: unused_pid)
      successor = Process.ppid
      # 検査のあいだに別の start が奪った状態を作る。
      daemon.define_singleton_method(:alive_state) do
        File.write(pid_file, successor.to_s)
        next :alive
      end

      output = capture_stdout {daemon.send(:run_status)}

      assert_not_match(/is running/, output, '死んだ番号を running と言わないこと')
      assert_match(/changed while checking/, output)
    end

    # 🔴🔴 **2 回目の読み取りで失敗したら、`status` もそう言うこと (#635 Codex P2・4 巡目)。**
    # ⚠⚠ 番号を持ったまま `:unknown` を報告すると、**「その pid は他人のもの」という
    # 別の話に化ける** — 実際には読めなかっただけ。
    def test_run_status_reports_a_failed_second_read
      daemon = create(pid: unused_pid)
      original = stub_read_error(daemon, Errno::EIO, on: 2)

      output = capture_stdout {daemon.send(:run_status)}

      assert_match(/could not be read/, output)
      assert_not_match(/is not ours/, output)
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **2 つの読み取りの間に別の start が pid ファイルを作っても、番号の無い
    # メッセージにしないこと (#635 Codex P2・4 巡目)。**
    def test_abort_if_running_never_reports_an_empty_pid
      daemon = create
      daemon.define_singleton_method(:alive_state) {:alive}

      output = capture_stderr do
        assert_raise(SystemExit) {daemon.send(:abort_if_running!)}
      end

      assert_equal('already running', daemon.logs.first.last[:reason])
      assert_not_match(/\(PID \)/, output, '番号の無い括弧を出さないこと')
      assert_match(/PID file/, output)
    end

    # 🔴🔴 **`status` が壊れた行を出さないこと (#635 Codex P2・3 巡目)。**
    #
    # ⚠ 番号と状態を別々の読み取りから出していると、⚠⚠ **片方だけ失敗したときに
    # `is running (PID )` になる** — しかも一過性の失敗、つまりこの PR が扱っている
    # まさにその状況で。
    def test_run_status_never_prints_an_empty_pid
      daemon = create(pid: Process.ppid)
      original = stub_read_error(daemon, Errno::EIO, on: 1)

      output = capture_stdout {daemon.send(:run_status)}

      assert_not_match(/PID \)/, output, '番号の無い running を出さないこと')
      assert_match(/could not be read/, output)
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **上書きされた `alive_state` の中で失敗が消えないこと (#635 Codex P2・5 巡目)。**
    #
    # ⚠ 利用側（`makoto2`）は `super` のあとにもう一度 `pid` を呼ぶ。⚠⚠ **読み取りごとに
    # 記録を消していると、途中の失敗が後の成功で消える** — 前後で挟むだけでは
    # 原理的に見えない窓。🔴 消えると「読めなかった」が「他人の pid」に化け、
    # override が :dead を返す形なら**起動まで通る**。
    def test_refusal_keeps_an_error_cleared_inside_the_override
      daemon = create(pid: unused_pid)
      # `super` のあとに読み直す形（利用側の実物と同じ）。
      daemon.define_singleton_method(:alive_state) do
        state = super()
        pid
        next state
      end
      original = stub_read_error(daemon, Errno::EIO, on: 2)

      assert_raise(SystemExit) {daemon.send(:abort_if_running!)}
      assert_equal('pid file unreadable', daemon.logs.first.last[:reason])
      assert_equal('Errno::EIO', daemon.logs.first.last[:error])
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **2 回目の読み取りで失敗しても、理由が残ること (#635 Codex P2・2 巡目)。**
    #
    # ⚠ 1 回目（門の手前）は通り、`alive_state` の中の読み取りで失敗する窓。
    # ⚠⚠ **状態が決められていない**ので、`:unknown` として番号入りで報告するのではなく
    # 「読めなかった」で拒む。
    def test_refusal_keeps_the_error_from_the_second_read
      daemon = create(pid: unused_pid)
      original = stub_read_error(daemon, Errno::EIO, on: 2)

      assert_raise(SystemExit) {daemon.send(:abort_if_running!)}
      assert_equal('Errno::EIO', daemon.logs.first.last[:error], '読めなかった理由が残ること')
      assert_equal('pid file unreadable', daemon.logs.first.last[:reason])
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **上書きされた `alive_state` が :dead と答えても、読めないなら起動しない (#635)。**
    #
    # ⚠ 利用側（`makoto2`）は `alive_state` を上書きし、`super` のあと `pid` を呼び直して
    # `pid&.positive?` で判定している。⚠⚠ **`pid` は「無い」も「読めない」も nil に
    # 畳む**ので、読めないときに :dead へ化ける — そこから**生きている常駐の pid
    # ファイルを奪いにいける**。上流で拒む。
    def test_abort_if_running_refuses_when_the_pid_file_cannot_be_read
      daemon = create(pid: unused_pid)
      daemon.define_singleton_method(:alive_state) {:dead}
      original = stub_read_error(daemon, Errno::EIO)

      assert_raise(SystemExit) {daemon.send(:abort_if_running!)}
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **ハードリンクされた pid ファイルでリンク先を壊さない (#632 / #643)。**
    #
    # 旧版は pid ファイルの inode に書いていたので、`link(victim, pid_file)` で
    # victim が pid の数字で上書き＋ truncate された（#632 では拒んで塞いだ）。
    # いまは新しい inode を `rename` するので、置き換わるのは名前だけ。
    # Linux の `fs.protected_hardlinks` は緩和だが、FreeBSD の既定には無い。
    def test_write_pid_replaces_a_hard_linked_pid_file_without_touching_the_target
      daemon = create
      victim = File.join(@dir, 'victim')
      File.write(victim, 'secret')
      FileUtils.rm_f(daemon.pid_file)
      File.link(victim, daemon.pid_file)

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal('secret', File.read(victim), 'リンク先を壊さないこと')
      assert_equal(1, File.stat(victim).nlink, 'リンク先から名前が外れていること')
      assert_equal(Process.pid, daemon.pid)
    end

    # ⚠ **置き換えても跡は残す。** `cp -al` のようなスナップショットでなければ、
    # 誰かが仕掛けている。
    def test_write_pid_logs_a_hard_linked_pid_file
      daemon = create
      victim = File.join(@dir, 'victim')
      File.write(victim, 'secret')
      FileUtils.rm_f(daemon.pid_file)
      File.link(victim, daemon.pid_file)

      daemon.send(:write_pid)

      assert_include(daemon.logs.map {|_severity, message| message[:message]},
        'pid file is hard linked')
    end

    # 🔴🔴 **検査のあとに経路をすり替えられても、リンク先を壊さない (#643 の芯)。**
    #
    # 旧版は `nlink` と `lstat` の同一性で確かめていたが、確かめたあとに張り直される形は
    # 閉じられなかった（検査と書き込みが原子的でないため）。いまは検査の結果に頼って
    # いない — 書くのは自分が作った inode だけ。
    # 🔴 **すり替えが起きたことまで assert する。** 割り込み先（`pid_file_stat`）の名前が
    # 変わると、このテストは何もせずに緑になる（実際に一度そうなっていた — リリース前
    # レビューの直しで割り込み先を消したとき）。
    def test_write_pid_survives_a_link_swapped_in_after_the_check
      daemon = create(pid: unused_pid)
      victim = File.join(@dir, 'victim')
      File.write(victim, 'secret')
      swapped = false
      daemon.define_singleton_method(:pid_file_stat) do
        found = super()
        FileUtils.rm_f(pid_file)
        File.link(victim, pid_file)
        swapped = true
        next found
      end

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_true(swapped, '前提: 検査のあとですり替えたこと')
      assert_equal('secret', File.read(victim), 'リンク先を壊さないこと')
      assert_equal(Process.pid, daemon.pid)
    end

    # 🔴🔴 **読み直しが読めなかったとき、「無いまま」と読んで置き換えない**（リリース前レビュー）。
    #
    # `read_pid_file` は「無い」も「読めない」も nil なので、1 回目が「無い」だと
    # 比べるだけでは同じに見える。⚠⚠ その間に現れた pid ファイル（ロックを取らない
    # 旧版の start が書いたもの）を上書きし、その 1 本を孤児にしていた。
    def test_write_pid_does_not_replace_after_a_failed_reread
      daemon = create
      successor = Process.ppid
      reads = 0
      daemon.define_singleton_method(:read_pid_file) do
        reads += 1
        next super() unless reads == 2
        File.write(pid_file, successor.to_s)
        @pid_file_error = Errno::EACCES.new(pid_file)
        next nil
      end

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_equal(successor, File.read(daemon.pid_file).to_i, '後から書かれた pid を残すこと')
    end

    # ⚠⚠ **ロックを取ったあとで、そのパスがまだ同じ inode か確かめる**（リリース前レビュー）。
    # 判断の最中にロック専用ファイルを消されると、次の start は新しい inode でロックを
    # 取れてしまい、2 本とも起動しうる。消された inode を握ったままの周回では判断しない。
    def test_write_pid_does_not_decide_under_a_removed_lock
      daemon = create
      locks = 0
      daemon.define_singleton_method(:lock_pid_file) do |file|
        locked = super(file)
        locks += 1
        File.unlink(pid_lock_file) if locks == 1
        next locked
      end
      held = []
      daemon.define_singleton_method(:try_acquire_pid_file) do
        held.push(File.exist?(pid_lock_file))
        next super()
      end

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(2, locks, '消された周回は捨てて取り直すこと')
      assert_equal([true], held, '消されたロックの下では判断しないこと')
    end

    # ⚠ **ロックは `0600`、pid ファイルは `0644` で作る**（リリース前レビュー）。
    # ロックを読めるだけの相手でも `flock` を握り続けて起動を止められる。pid ファイルが
    # グループに書けると、`stop` が別のプロセスへ `TERM` を送る。
    # ⚠ umask に左右されないことを測るので、あえて緩い umask で作る。
    # 🔴🔴 **置き換えた古い inode のロックを放さない (#643 Codex P1・2 巡目)。**
    #
    # 旧版が open と `flock` の間でスケジュールから外れた形。置き換えが済んでから
    # 消えた inode の `flock` を取れてしまうと、旧版はそこへ書いて「取れた」と読む。
    def test_write_pid_keeps_the_old_inode_locked_for_a_paused_old_starter
      daemon = create(pid: unused_pid)
      File.open(daemon.pid_file, File::RDWR) do |old|
        assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
        assert_equal(Process.pid, daemon.pid)

        assert_false(old.flock(File::LOCK_EX | File::LOCK_NB), '旧版が消えた inode を取れないこと')
      end
    end

    # 🔴🔴 **無かった pid ファイルを、読み直しのあとで旧版に作られた形 (#643 Codex P1・3 巡目)。**
    #
    # 無いときは握る古い inode が無いので、旧版が `O_EXCL` で作って `flock` の手前で止まると、
    # `rename` がそれを上書きしていた。`link` で置けば `EEXIST` で気づき、次の周回で
    # 旧版のファイルを握ってから置き換える。
    def test_write_pid_does_not_overwrite_a_pid_file_created_by_an_old_starter
      daemon = create
      legacy = nil
      daemon.define_singleton_method(:install_pid_file) do |temp, stat|
        legacy ||= File.new(pid_file, File::RDWR | File::CREAT | File::EXCL)
        next super(temp, stat)
      end

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
      assert_false(legacy.flock(File::LOCK_EX | File::LOCK_NB), '旧版が消えた inode を取れないこと')
      assert_equal([], Dir.glob("#{daemon.pid_file}.*.tmp"), '一時ファイルを残さないこと')
    ensure
      legacy&.close
    end

    # ⚠ **在ったときも、置く直前にパスが握った inode を指すか確かめる。** 消されたあとに
    # 旧版が作り直した形を上書きしない。
    def test_write_pid_does_not_overwrite_a_pid_file_recreated_by_an_old_starter
      daemon = create(pid: unused_pid)
      legacy = nil
      daemon.define_singleton_method(:install_pid_file) do |temp, stat|
        unless legacy
          File.unlink(pid_file)
          legacy = File.new(pid_file, File::RDWR | File::CREAT | File::EXCL)
        end
        next super(temp, stat)
      end

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
      assert_false(legacy.flock(File::LOCK_EX | File::LOCK_NB), '旧版が作り直した inode を取れないこと')
      assert_equal([], Dir.glob("#{daemon.pid_file}.*.tmp"), '一時ファイルを残さないこと')
    ensure
      legacy&.close
    end

    # 🔴 **`exec` をまたいでも握り続ける。** 常駐は `write_pid` のあとに `exec` するので、
    # close-on-exec のままだと、そこでロックが外れる。
    def test_write_pid_keeps_the_old_inode_locked_across_exec
      daemon = create(pid: unused_pid)
      File.open(daemon.pid_file, File::RDWR) do |old|
        child = fork do
          $stderr.reopen(File::NULL)
          daemon.send(:write_pid)
          exec('sleep', '10')
        end
        begin
          Timeout.timeout(10) {sleep(0.05) until File.read(daemon.pid_file) == child.to_s}
          sleep(0.3)

          assert_false(old.flock(File::LOCK_EX | File::LOCK_NB), 'exec のあとも握っていること')
        ensure
          Process.kill('KILL', child)
          Process.waitpid(child)
        end

        # 前提: 常駐が終われば外れる（このテストが「握っていること」を測っている）。
        assert_equal(0, old.flock(File::LOCK_EX | File::LOCK_NB))
      end
    end

    # 🔴 **厳しい umask でも pid ファイルは `0644`** (#643 Codex P2)。作るときの引数は
    # umask で削られるので、`077` だと `0600` になり、監視から読めなくなっていた。
    def test_write_pid_fixes_the_modes
      [0o000, 0o077].each do |mask|
        daemon = create
        FileUtils.rm_f(daemon.pid_lock_file)
        original = File.umask(mask)
        begin
          daemon.send(:write_pid)
        ensure
          File.umask(original)
        end

        assert_equal(0o600, File.stat(daemon.pid_lock_file).mode & 0o777, "umask #{mask.to_s(8)}")
        assert_equal(0o644, File.stat(daemon.pid_file).mode & 0o777, "umask #{mask.to_s(8)}")
      end
    end

    # 🔴🔴 **移行期の旧版（1.24.0 まで）の start と排他を合わせる (#643 Codex P1)。**
    #
    # 旧版は `O_EXCL` で pid ファイルを作り、その inode に `flock` を取ってから pid を書く。
    # ⚠⚠ その途中（空のまま）を新版が「変わっていない」と読んで置き換えると、旧版は
    # 消えた inode に書いて「取れた」と読み、2 本とも起動する。
    # ⚠ 旧版が異常終了で残った pid ファイルを奪うとき（`reclaim_pid_file`）も同じ形。
    def test_write_pid_waits_for_an_old_starter_holding_the_pid_file
      daemon = create
      File.open(daemon.pid_file, File::RDWR | File::CREAT | File::EXCL) do |old|
        old.flock(File::LOCK_EX)
        inode = old.stat.ino

        output = capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}

        assert_match(/the PID file kept changing/, output)
        assert_equal(inode, File.stat(daemon.pid_file).ino, '旧版が握っている pid ファイルを置き換えないこと')
        # 旧版が書き終えて放すと、新版はその pid を読んで止まる。
        old.write(Process.ppid.to_s)
        old.flush
      end

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_equal(Process.ppid, daemon.pid)
    end

    # ⚠⚠ **ロック専用ファイルは消さない (#643)。** 🔴 消すと、消す前の inode を
    # ロックした 1 本と、作り直された inode をロックした 1 本が両方「取れた」と読む。
    def test_pid_lock_file_is_kept
      daemon = create
      daemon.send(:write_pid)
      lock = File.stat(daemon.pid_lock_file)

      daemon.send(:remove_pid, Process.pid)

      assert_path_not_exist(daemon.pid_file)
      assert_equal(lock.ino, File.stat(daemon.pid_lock_file).ino, '同じ inode のまま残ること')
    end

    # 🔴🔴 **ロック専用ファイルの位置の symlink を辿らない (#643)。**
    # ⚠ 辿ると `O_CREAT` が**リンク先にファイルを作る**。
    def test_write_pid_does_not_follow_a_symlinked_lock_file
      daemon = create
      victim = File.join(@dir, 'victim')
      File.symlink(victim, daemon.pid_lock_file)

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_path_not_exist(victim, 'リンク先に作らないこと')
      assert_path_not_exist(daemon.pid_file)
      assert_include(daemon.logs.map {|_severity, message| message[:reason]},
        'pid lock file unusable')
    end

    # 🔴 **ロック専用ファイルの位置の FIFO / ディレクトリで止まらない (#643)。**
    def test_write_pid_refuses_a_non_regular_lock_file
      daemon = create
      File.mkfifo(daemon.pid_lock_file)

      Timeout.timeout(5) do
        capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      end

      assert_include(daemon.logs.map {|_severity, message| message[:reason]},
        'pid lock file invalid')

      File.unlink(daemon.pid_lock_file)
      Dir.mkdir(daemon.pid_lock_file)

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_path_not_exist(daemon.pid_file)
    end

    # 🔴🔴 **`tmp/pids` 自体が symlink なら起動しない (#632)。**
    # ⚠⚠ `O_NOFOLLOW` が効くのは**パスの最終要素だけ**なので、置き場所を
    # 差し替えられると**リンク先のファイルを掴まされる**。
    def test_write_pid_refuses_when_the_pid_dir_is_a_symlink
      elsewhere = File.join(@dir, 'elsewhere')
      FileUtils.mkdir_p(elsewhere)
      pids = File.join(@dir, 'tmp/pids')
      FileUtils.remove_entry(pids)
      File.symlink(elsewhere, pids)
      daemon = create
      victim = daemon.pid_file
      File.write(victim, 'secret')

      assert_raise(SystemExit) {daemon.send(:write_pid)}
      assert_equal('secret', File.read(victim), 'リンク先のファイルを壊さないこと')
    end

    # 🔴🔴 **最終要素だけ見ても足りない (#632 Codex P1)。**
    #
    # ⚠⚠ `tmp` の側を symlink にすれば、`tmp/pids` は**本物のディレクトリ**なので
    # 検査を通る — 🔴 実測で victim が pid の数字で上書きされた。
    def test_write_pid_refuses_when_an_ancestor_is_a_symlink
      elsewhere = File.join(@dir, 'elsewhere')
      FileUtils.mkdir_p(File.join(elsewhere, 'pids'))
      FileUtils.remove_entry(File.join(@dir, 'tmp'))
      File.symlink(elsewhere, File.join(@dir, 'tmp'))
      daemon = create
      victim = daemon.pid_file
      File.write(victim, 'secret')

      assert_raise(SystemExit) {daemon.send(:write_pid)}
      assert_equal('secret', File.read(victim), 'リンク先のファイルを壊さないこと')
    end

    # ⚠ **拒むときは原因の段を名乗る。** 🔴 `tmp/pids` を出すと、運用者は
    # 「ディレクトリはあるのに」となる（symlink なのは `tmp` の側）。
    def test_write_pid_names_the_unusable_directory
      elsewhere = File.join(@dir, 'elsewhere')
      FileUtils.mkdir_p(File.join(elsewhere, 'pids'))
      FileUtils.remove_entry(File.join(@dir, 'tmp'))
      File.symlink(elsewhere, File.join(@dir, 'tmp'))
      daemon = create

      output = capture_stderr do
        assert_raise(SystemExit) {daemon.send(:write_pid)}
      end

      assert_match(/#{Regexp.escape(File.join(@dir, 'tmp'))}'/, output)
    end

    # ⚠⚠ **作業ディレクトリより上は見ない (#632)。** 🔴 Capistrano 式の `current` のように
    # **上に symlink を置く運用は正当**で、そこを拒むと配置ごと壊す。
    def test_write_pid_allows_a_symlinked_working_dir
      real = File.join(@dir, 'releases/1')
      FileUtils.mkdir_p(File.join(real, 'tmp/pids'))
      link = File.join(@dir, 'current')
      File.symlink(real, link)
      daemon = Stub.new({application: 'GinsengDaemonTest', working_dir: link})

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # ⚠ **素のディレクトリなら従来どおり取れる。** 🔴 置き場所の検査を入れたことで
    # **普通の起動が拒まれていないこと**を固定する。
    def test_write_pid_accepts_a_plain_pid_dir
      daemon = create

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # 🔴🔴 **FIFO を置かれても止まらないこと (#633 Codex P1)。**
    #
    # pid ファイルの位置に FIFO があると、⚠⚠ **書き手が現れるまで `open` も `read` も
    # 返らない** — `status` / `start` / `restart` が丸ごとハングする。
    # ⚠ このファイルは `LOCK_NB` でハングを避けているのに、読む側から入られていた。
    def test_pid_does_not_block_on_a_fifo
      daemon = create
      File.mkfifo(daemon.pid_file)

      Timeout.timeout(5) do
        assert_nil(daemon.pid)
        assert_equal(:dead, daemon.alive_state)
        assert_raise(SystemExit) {daemon.send(:write_pid)}
      end
    end

    # 🔴 **中身が読めてしまう FIFO でも、pid として受け取らないこと (#633)。**
    # ⚠ 書き手が居ると `O_NONBLOCK` でも中身は読める。**型で弾く**のはそのため。
    def test_pid_ignores_a_fifo_with_a_writer
      daemon = create
      File.mkfifo(daemon.pid_file)
      File.open(daemon.pid_file, File::RDONLY | File::NONBLOCK) do |_reader|
        File.open(daemon.pid_file, File::WRONLY | File::NONBLOCK) do |writer|
          writer.write(Process.ppid.to_s)
          writer.flush

          Timeout.timeout(5) {assert_nil(daemon.pid, 'FIFO の中身を pid にしないこと')}
        end
      end
    end

    # 🔴🔴 **書いたあとの失敗で起動しないこと (#633 Codex P2 / #643)。**
    #
    # ⚠ `rename` まで届かなければ pid ファイルは自分のものになっていない。
    # ⚠⚠ **作った一時ファイルは残さない** — 名前の形で掃除すると他人のファイルを
    # 消しうるので、あとから拾う手段が無い。
    def test_write_pid_does_not_start_after_a_failed_rename
      stale = unused_pid
      daemon = create(pid: stale)
      original = File.method(:rename)
      File.define_singleton_method(:rename) {|_from, to| raise Errno::EIO, to}

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      File.define_singleton_method(:rename, original)

      assert_equal(stale, daemon.pid, 'pid ファイルは元のまま')
      assert_equal([], Dir.glob("#{daemon.pid_file}.*.tmp"), '一時ファイルを残さないこと')
    ensure
      File.define_singleton_method(:rename, original) if original
    end

    # 🔴🔴 **一時ファイルへの書き込み（close / writeback）の失敗でも起動しないこと。**
    def test_write_pid_does_not_start_after_a_late_write_error
      daemon = create
      original = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, &block|
        next original.call(path, *args, &block) unless args.first == Daemon::PidFile::PID_TEMP_OPEN_FLAGS
        original.call(path, *args) do |file|
          file.define_singleton_method(:write) {|*| raise Errno::ENOSPC, path}
          next block.call(file)
        end
      end

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      File.define_singleton_method(:open, original)

      assert_path_not_exist(daemon.pid_file)
      assert_equal([], Dir.glob("#{daemon.pid_file}.*.tmp"), '一時ファイルを残さないこと')
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **`O_NOFOLLOW` の errno はプラットフォームで違う (#633)。**
    #
    # Linux / macOS は `ELOOP`、**FreeBSD は `EMLINK`**（キュアスタ！の本番は FreeBSD）。
    # ⚠⚠ **errno を列挙すると、そこでだけ例外が突き抜ける** — `run_restart` の子は
    # stderr を `/dev/null` へ付け替えているので、backtrace すら残らない。
    def test_write_pid_gives_up_cleanly_on_a_freebsd_style_nofollow_error
      daemon = create(pid: unused_pid)
      original = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, &block|
        raise Errno::EMLINK, path if args.first == Daemon::PidFile::PID_LOCK_OPEN_FLAGS
        next original.call(path, *args, &block)
      end

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_equal([[:error, 'pid lock file unusable', 'Errno::EMLINK']],
        daemon.logs.map {|severity, message| [severity, message[:reason], message[:error]]})
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # ⚠⚠ **ロック専用ファイルを作れないときも、例外のまま抜けないこと。**
    #
    # `tmp/pids` が書けない・ro・満杯・fd 枯渇のとき、⚠⚠ **`run_restart` の子では
    # backtrace も消え、親は exit 0 で返る** — 落ちているのにログが 1 行も増えない
    # （旧版の `create_pid_file` で出た赤と同じ形）。
    def test_write_pid_gives_up_cleanly_when_the_lock_file_cannot_be_created
      daemon = create
      original = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, &block|
        raise Errno::EACCES, path if args.first == Daemon::PidFile::PID_LOCK_OPEN_FLAGS
        next original.call(path, *args, &block)
      end

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_equal([[:error, 'pid lock file unusable', 'Errno::EACCES']],
        daemon.logs.map {|severity, message| [severity, message[:reason], message[:error]]})
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # ⚠ **ロック操作そのものの失敗も理由を名乗る**（リリース前レビュー）。
    # 例外のまま抜けると `run_start` の rescue が `Could not start` と言うだけで、
    # 理由がロックだと読めない。
    def test_write_pid_names_a_failed_lock
      daemon = create
      daemon.define_singleton_method(:lock_pid_file) {|_file| raise Errno::ENOLCK, 'flock'}

      capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}
      assert_equal([[:error, 'pid lock failed', 'Errno::ENOLCK']],
        daemon.logs.map {|severity, message| [severity, message[:reason], message[:error]]})
    end

    # 🔴 **pid ファイルの位置の symlink は置き換えない (#629 / #643)。**
    #
    # ⚠ `rename` なら symlink の先には書かないので壊れはしないが、この位置に symlink が
    # 置かれる正当な形が無いので、止めて知らせる（旧方式では、辿ると中身が pid の数字で
    # 上書き＋ truncate された）。
    def test_write_pid_refuses_a_symlinked_pid_file
      daemon = create
      victim = File.join(@dir, 'victim')
      File.write(victim, 'do not touch')
      File.symlink(victim, daemon.pid_file)

      output = capture_stderr {assert_raise(SystemExit) {daemon.send(:write_pid)}}

      assert_equal('do not touch', File.read(victim), 'リンク先を書き替えないこと')
      # ⚠ 後ろの `O_NOFOLLOW` の open も止めるが、それだと理由が「lock failed」になって原因が読めない。
      assert_match(/is not a valid PID file \(link\)/, output)
    end

    # ⚠⚠ **上限の内側は通ること。** 🔴 外側だけを測ると、`<` と `<=` の取り違えを
    # 素通りさせる（実際、上限を 11 バイトや 4096 バイトへ動かしてもスイートは
    # 全緑だった — リリース前レビューの実測）。
    def test_pid_accepts_the_boundaries
      daemon = create

      # 番号の上端ちょうど（`pid_t` の最大）。
      File.write(daemon.pid_file, '2147483647')

      assert_equal(2_147_483_647, daemon.pid)

      # 読む量の上限ちょうど（64 バイト）。⚠ 期待値は**リテラル**で置く — 定数から
      # 作ると、実装と一緒に動いて何も固定しない。
      File.write(daemon.pid_file, "123#{' ' * 61}")

      assert_equal(64, File.size(daemon.pid_file))
      assert_equal(123, daemon.pid)
    end

    # ⚠⚠ **不正な UTF-8 バイトで例外を上げないこと。** 🔴 長さを渡さない `File.read` は
    # UTF-8 で返るので、`strip` / `match?` が `Encoding::CompatibilityError` を上げ、
    # `pid` を呼んだ側が落ちる（`run_restart` は途中で抜けて後継を fork しない）。
    def test_pid_tolerates_invalid_byte_sequences
      daemon = create
      File.binwrite(daemon.pid_file, "123\xFF")

      assert_nothing_raised {daemon.pid}
      assert_nil(daemon.pid)
    end

    # ⚠⚠ **範囲外の番号でも「起動を永久に拒む」に落ちないこと (#629 Codex P2)。**
    def test_write_pid_reclaims_a_pid_file_out_of_range
      daemon = create
      File.write(daemon.pid_file, '9999999999')

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # ⚠ **pid ファイルは丸ごと読まない (#629)。** 数桁と改行しか入らないので、
    # 🔴 壊れたファイルや細工されたファイルをメモリへ載せる理由が無い。
    def test_read_pid_file_is_bounded
      daemon = create
      File.write(daemon.pid_file, '9' * 10_000)

      # ⚠ 期待値は**リテラル**（65 = 上限 64 ＋ 超過を知るための 1 バイト）。
      # 🔴 定数から作ると実装と一緒に動いて、上限が何であっても緑になる。
      assert_equal(65, daemon.send(:read_pid_file).bytesize,
        '上限を超えていることが分かるだけ余分に読むこと')
    end

    # ⚠⚠ **排他は分岐を並べても測れない。実際に同時へ走らせる (#622 / #643)。**
    def test_write_pid_has_exactly_one_winner
      daemon = create
      # ⚠ **バリアを張らないと「同時」にならない。** 逐次に走っても同じ結果になる
      # ので、それでは排他ではなく「敗者が拒まれること」しか測れない（リリース前レビュー）。
      gate = IO.pipe
      # ⚠⚠ **勝った側は、全員の結果が出るまで生かしておく。** 先に終わると pid が
      # 死んだ番号になり、後から来た側が正当に置き換えて「勝つ」。
      hold = IO.pipe
      results = IO.pipe
      children = Array.new(4) do
        fork do
          [gate.last, hold.last, results.first].each(&:close)
          $stderr.reopen(File::NULL)
          gate.first.read(1)
          outcome = begin
            daemon.send(:write_pid)
            'W'
          rescue SystemExit
            daemon.logs.last&.last&.dig(:reason) == 'already running' ? 'A' : 'C'
          end
          results.last.write(outcome)
          results.last.close
          hold.first.read(1)
          exit!(0)
        end
      end
      [gate.first, hold.first, results.last].each(&:close)
      gate.last.write('x' * children.size)
      gate.last.close
      outcome = results.first.read
      hold.last.close
      children.each {|child| Process.waitpid(child)}

      assert_equal(4, outcome.size)
      assert_equal(1, outcome.count('W'), '勝てるのは 1 本だけ')
      # 🔴 **負けた側は「already running」で終わること**（リリース前レビュー）。周回の間で
      # 待たないと、勝ち側がロックを握っている数 ms で周回を使い切り、原因の読めない
      # 「Could not acquire」になる。
      assert_equal(3, outcome.count('A'), "負け方: #{outcome}")
      assert_path_exist(daemon.pid_file)
    end

    private

    # 読む経路の `File.open` にだけ errno を注入する。
    #
    # ⚠⚠ **注入点は実装が実際に通る場所に置くこと。** 🔴 `File.read` / `File.file?` に
    # 挿していた版は、実装が `File.open` を使うようになった時点で**何も測らなくなった**
    # （リリース前レビューで踏んだ形と同じ）。
    # `on:` を渡すと**その回の読み取りだけ**失敗する。⚠⚠ **何回目で失敗するかで
    # 通る道が変わる** — 1 回目なら「読めない」で即拒み、2 回目なら `alive_state` の
    # 中で失敗するので、そこを区別できないと窓が残る（#635 Codex P2）。
    def stub_read_error(daemon, error, once: false, on: nil)
      target = daemon.pid_file
      original = File.method(:open)
      reads = 0
      File.define_singleton_method(:open) do |path, *args, &block|
        if path == target && args.first == Daemon::PidFile::PID_FILE_READ_FLAGS
          reads += 1
          raise error, path if on ? reads == on : !(once && reads > 1)
        end
        next original.call(path, *args, &block)
      end
      return original
    end

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      return $stdout.string
    ensure
      $stdout = original
    end

    # ⚠ `warn` の行も測る。🔴 ログの `reason` だけ見ていると、**運用者が実際に読む
    # 文言**（`(PID )` のような壊れた形）を素通りさせる。
    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
      return $stderr.string
    ensure
      $stderr = original
    end

    def create(pid: nil, error: nil)
      daemon = Stub.new({application: 'GinsengDaemonTest', working_dir: @dir, error:})
      # ⚠ **同じ working_dir を使い回すので、状態は毎回作り直す。**
      # 🔴 `pid:` 無しを「pid ファイルが無い」の意味で使うテストが、前のテストの
      # 書いたものを拾っていた。
      FileUtils.rm_f(daemon.pid_file)
      File.write(daemon.pid_file, pid.to_s) if pid
      return daemon
    end

    # 使われていない pid。実際に存在しないことを確かめてから返す。
    def unused_pid
      (2**15).downto(2) do |pid|
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return pid
      rescue Errno::EPERM # rubocop:disable Lint/SuppressedException
      end
      return nil
    end
  end
end
