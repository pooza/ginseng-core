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
      attr_reader :signals

      def initialize(opts = {})
        super
        @signals = []
        @error = opts[:error]
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
      target = daemon.pid_file
      original = File.method(:file?)
      # File.file? の直後に消える状況を作る。
      File.define_singleton_method(:file?) do |path|
        FileUtils.rm_f(path) if path == target
        original.call(path) || path == target
      end

      assert_nil(daemon.pid)
    ensure
      File.define_singleton_method(:file?, original) if original
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
    # ⚠⚠ **剥がさないこと**まで測る — 剥がすと次の start が 2 本目を立てる。
    def test_write_pid_refuses_when_owner_is_unknown
      stale = unused_pid
      daemon = create(pid: stale)
      daemon.define_singleton_method(:alive_state) {:unknown}

      assert_raise(SystemExit) {daemon.send(:write_pid)}
      assert_equal(stale, daemon.pid, 'pid ファイルを剥がさないこと')
    end

    # ⚠⚠ **異常終了で残った pid ファイルは剥がして取り直す (#622)。**
    # `O_EXCL` だけで済ませると、**そのファイルが起動を永久に阻む**。
    def test_write_pid_reclaims_dead_pid_file
      daemon = create(pid: unused_pid)

      daemon.send(:write_pid)

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

      daemon.send(:write_pid)

      assert_equal(Process.pid, daemon.pid)
    end

    # 🔴 **剥がしてよいのは「自分が死んでいると判断した pid のまま」のときだけ (#532)。**
    # 判断してから剥がすまでの間に別の start が取り直していたら、それは他人の pid
    # ファイルで、⚠⚠ **消せばその 1 本を孤児にする**。
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
    def test_reclaim_pid_file_yields_while_locked
      stale = unused_pid
      daemon = create(pid: stale)
      File.open(daemon.pid_file, File::RDWR) do |holder|
        holder.flock(File::LOCK_EX)

        assert_false(daemon.send(:reclaim_pid_file, stale), 'ロックを取れなければ奪わない')
        assert_equal(stale, daemon.pid, '中身を書き替えないこと')
      end
    end

    # 🔴 **ロックを取ってから読み直すこと。** 待っている間に別の start が奪って
    # いれば、それはもう自分が「死んでいる」と判断した pid ファイルではない。
    def test_reclaim_pid_file_gives_up_when_content_changed
      daemon = create(pid: Process.ppid)

      assert_false(daemon.send(:reclaim_pid_file, unused_pid))
      assert_equal(Process.ppid, daemon.pid, '中身を書き替えないこと')
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

      daemon.send(:write_pid)

      assert_equal([], removed, 'pid ファイルを消さずに奪うこと')
      assert_equal(Process.pid, daemon.pid)
    ensure
      FileUtils.define_singleton_method(:rm_f, original) if original
    end

    # ⚠⚠ **原子性は分岐を並べても測れない。実際に同時へ走らせる (#622)。**
    # 🔴 `File.write` に戻すと**全員が勝つ**ので、このテストだけが落ちる。
    def test_create_pid_file_has_exactly_one_winner
      daemon = create
      children = Array.new(4) {fork {exit(daemon.send(:create_pid_file) ? 0 : 1)}}

      winners = children.count do |child|
        Process.waitpid2(child).last.success?
      end

      assert_equal(1, winners, '勝てるのは 1 本だけ')
      assert_path_exist(daemon.pid_file)
    end

    private

    def create(pid: nil, error: nil)
      daemon = Stub.new({application: 'GinsengDaemonTest', working_dir: @dir, error:})
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
