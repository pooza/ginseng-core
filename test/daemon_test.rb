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

    # ⚠⚠ **異常終了で残った pid ファイルは奪って起動する (#622)。**
    # `O_EXCL` だけで済ませると、**そのファイルが起動を永久に阻む**。⚠ 奪うのは
    # **中身の差し替え**で、消しはしない（→ `test_write_pid_never_unlinks`）。
    def test_write_pid_reclaims_dead_pid_file
      daemon = create(pid: unused_pid)

      # ⚠⚠ **`SystemExit` は受けること** — 素で投げさせるとスイート自体が途中で
      # 終わり、🔴 **test-unit は「100% passed」のまま件数だけ減らす**（実測）。
      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # ⚠⚠ **自分が既に取っている pid ファイルで自分を殺さないこと。**
    # 🔴 `O_EXCL` にした以上、2 度目の呼び出しは必ず作成に失敗する — そこで
    # `alive_state` を見ると**自分の pid が :alive** なので「already running」になる。
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

    # ⚠⚠ **奪えるのはロックを取れた 1 本だけ (#622 Codex P1)。**
    # 別の start が握っている間は奪わずに諦める（次の周回で読み直す）。
    def test_reclaim_pid_file_gives_up_while_locked
      stale = unused_pid
      daemon = create(pid: stale)
      File.open(daemon.pid_file, File::RDWR) do |holder|
        holder.flock(File::LOCK_EX)

        assert_false(daemon.send(:reclaim_pid_file, stale.to_s), 'ロックを取れなければ奪わない')
        assert_equal(stale, daemon.pid, '中身を書き替えないこと')
      end
    end

    # ⚠ 中身が自分の見たものと違えば奪わない。⚠⚠ **「ロックの中で読み直している」
    # ことまでは測れていない**（競合相手が居ないので、ロックの前に読む実装でも緑に
    # なる）。そちらは `test_create_pid_file_backs_off_when_taken_before_the_lock`
    # と `test_reclaim_pid_file_gives_up_while_locked` の 2 本で押さえている。
    def test_reclaim_pid_file_gives_up_when_content_changed
      daemon = create(pid: Process.ppid)

      assert_false(daemon.send(:reclaim_pid_file, unused_pid.to_s))
      assert_equal(Process.ppid, daemon.pid, '中身を書き替えないこと')
    end

    # 🔴🔴 **見捨てられた空の pid ファイルから復帰できること (#622 Codex P1)。**
    #
    # `O_EXCL` に勝った 1 本が pid を書く前に死ぬと、**中身の無い pid ファイル**が
    # 残る。⚠⚠ **ここを「取得の途中かもしれない」と読んで拒むと、失敗した 1 回の
    # 起動が恒久的な起動不能に化ける**（手で消すまで直らない）。
    #
    # ⚠ 奪ってよいのは、**奪われた側が書き戻さない**から
    # （→ `test_create_pid_file_backs_off_when_taken_before_the_lock`）。
    def test_write_pid_reclaims_an_abandoned_empty_pid_file
      daemon = create
      File.write(daemon.pid_file, '')

      assert_nothing_raised(SystemExit) {daemon.send(:write_pid)}
      assert_equal(Process.pid, daemon.pid)
    end

    # 🔴🔴 **作成から flock までの隙間で奪われていたら、書かずに負けを認めること。**
    # ⚠⚠ **これが無いと、空のファイルを奪った側と作った側の 2 本が起動する。**
    def test_create_pid_file_backs_off_when_taken_before_the_lock
      daemon = create
      successor = Process.ppid
      # flock を取る直前に別の start が奪った状態を作る（実プロセスでは順序を握れない）。
      daemon.define_singleton_method(:lock_pid_file) do |file|
        File.write(pid_file, successor.to_s)
        next file.flock(File::LOCK_EX)
      end

      assert_false(daemon.send(:create_pid_file), '奪われていたら負けを認めること')
      assert_equal(successor, daemon.pid, '奪った側の pid を上書きしないこと')
    end

    # ⚠⚠ **触れない pid ファイルで落ちないこと。** 別ユーザーが残したファイルは
    # 書けない。🔴 例外のまま抜けると backtrace だけが出て、運用者には理由が伝わらない。
    # ⚠ 権限そのものではなく `Errno::EACCES` の扱いを測る（CI は root で回るので、
    # chmod では再現できない）。🔴🔴 **ここで塞げるのは「開けない」側だけ** —
    # `File.read` は `File.open` を通らないので、**読めない側は
    # `test_pid_tolerates_an_unreadable_pid_file` で別に測る**（リリース前レビュー）。
    def test_write_pid_gives_up_cleanly_when_the_pid_file_cannot_be_opened
      daemon = create(pid: unused_pid)
      target = daemon.pid_file
      original = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, &block|
        flags = Daemon::PidFile::PID_FILE_OPEN_FLAGS
        raise Errno::EACCES, path if path == target && args.first == flags
        next original.call(path, *args, &block)
      end

      assert_raise(SystemExit) {daemon.send(:write_pid)}
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **start の経路で pid ファイルを消さないこと (#622 Codex P1)。**
    #
    # 「消して作り直す」だと、⚠⚠ **同じ stale を見た 2 本が両方 `remove_pid` の
    # 検査を通る** — 片方が消して作った直後に、もう片方の `rm_f` が**その新しい
    # pid ファイルを消す**。⚠ 奪うのは**中身の差し替え**で行い、ファイルの同一性を
    # 変えない（消される相手を作らない）。
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
    # `create_pid_file`、2 回目は `run_stop`）。**出口ごとに測る。**
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

    # 🔴🔴 **奪う側も、書き始めたあとの失敗で起動しないこと (#633 Codex P2)。**
    def test_write_pid_does_not_start_after_a_late_reclaim_error
      daemon = create(pid: unused_pid)
      daemon.define_singleton_method(:lock_pid_file) do |file|
        file.define_singleton_method(:truncate) {|_size| raise Errno::EIO, 'truncate'}
        next super(file)
      end

      assert_raise(SystemExit) {daemon.send(:write_pid)}
    end

    # 🔴🔴 **書いたあとの失敗を取り直しに混ぜないこと (#633 Codex P2)。**
    #
    # close / writeback が落ちると pid は書けているので、⚠⚠ **次の周回が「自分が
    # 既に取っている」と読んで、書けたか分からないまま起動する**。
    def test_write_pid_does_not_start_after_a_late_write_error
      daemon = create
      # 書いたあとの close で落ちる状況を作る。
      daemon.define_singleton_method(:lock_pid_file) do |file|
        file.define_singleton_method(:close) do
          super()
          raise Errno::EIO, 'close'
        end
        next super(file)
      end

      assert_raise(SystemExit) {daemon.send(:write_pid)}
    end

    # 🔴🔴 **`O_NOFOLLOW` の errno はプラットフォームで違う (#633)。**
    #
    # Linux / macOS は `ELOOP`、**FreeBSD は `EMLINK`**（キュアスタ！の本番は FreeBSD）。
    # ⚠⚠ **errno を列挙すると、そこでだけ例外が突き抜ける** — `run_restart` の子は
    # stderr を `/dev/null` へ付け替えているので、backtrace すら残らない。
    def test_write_pid_gives_up_cleanly_on_a_freebsd_style_nofollow_error
      daemon = create(pid: unused_pid)
      target = daemon.pid_file
      original = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, &block|
        flags = Daemon::PidFile::PID_FILE_OPEN_FLAGS
        raise Errno::EMLINK, path if path == target && args.first == flags
        next original.call(path, *args, &block)
      end

      assert_raise(SystemExit) {daemon.send(:write_pid)}
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **作れないときも「取れなかった」で終わること（リリース前レビューの赤）。**
    #
    # `create_pid_file` が `EEXIST` しか握らないと、⚠ `tmp/pids` が書けない・ro・
    # 満杯・fd 枯渇のときに例外のまま抜ける。⚠⚠ **`run_restart` の子では backtrace も
    # 消え、親は exit 0 で返る** — 落ちているのにログが 1 行も増えない。
    def test_write_pid_gives_up_cleanly_when_the_pid_file_cannot_be_created
      daemon = create
      target = daemon.pid_file
      original = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, &block|
        raise Errno::EACCES, path if path == target
        next original.call(path, *args, &block)
      end

      assert_raise(SystemExit) {daemon.send(:write_pid)}
    ensure
      File.define_singleton_method(:open, original) if original
    end

    # 🔴🔴 **symlink を辿らないこと (#629)。**
    #
    # 辿ると、pid ファイルを置き換えられる立場の相手に、⚠⚠ **デーモンのユーザーが
    # 書ける任意のファイルを壊させる**（中身が pid の数字で上書き＋ truncate される）。
    def test_write_pid_does_not_follow_a_symlink
      daemon = create
      victim = File.join(@dir, 'victim')
      File.write(victim, 'do not touch')
      File.symlink(victim, daemon.pid_file)

      assert_raise(SystemExit) {daemon.send(:write_pid)}
      assert_equal('do not touch', File.read(victim), 'リンク先を書き替えないこと')
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

    # ⚠⚠ **原子性は分岐を並べても測れない。実際に同時へ走らせる (#622)。**
    # 🔴 `File.write` に戻すと**全員が勝つ**ので、このテストだけが落ちる。
    def test_create_pid_file_has_exactly_one_winner
      daemon = create
      # ⚠ **バリアを張らないと「同時」にならない。** 逐次に走っても同じ結果になる
      # ので、それでは `O_EXCL` の原子性ではなく「敗者が false を返すこと」しか
      # 測れない（リリース前レビュー）。
      gate = IO.pipe
      children = Array.new(4) do
        fork do
          gate.last.close
          gate.first.read(1)
          exit(daemon.send(:create_pid_file) ? 0 : 1)
        end
      end
      gate.first.close
      gate.last.write('x' * children.size)
      gate.last.close

      winners = children.count do |child|
        Process.waitpid2(child).last.success?
      end

      assert_equal(1, winners, '勝てるのは 1 本だけ')
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
