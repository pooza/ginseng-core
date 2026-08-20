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
