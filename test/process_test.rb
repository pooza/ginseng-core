# frozen_string_literal: true

module Ginseng
  class ProcessTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def test_alive?
      assert(Process.alive?(0))
      assert(Process.alive?(Process.pid))
      assert_false(Process.alive?(-2))
    end

    def test_alive_state_alive
      assert_equal(:alive, Process.alive_state(Process.pid))
    end

    # ⚠ 存在しない pid は :dead。ESRCH をここで潰すと「居ないのに居る」になる。
    def test_alive_state_dead
      assert_equal(:dead, Process.alive_state(unused_pid))
    end

    # ⚠ **本件の芯** (#510)。`Errno::EPERM` は「存在するが触れない」であって
    # 「死んでいる」ではない。:dead と混ぜると、停止コマンドが孤児を作り、
    # start が 2 本目を立てる。
    def test_alive_state_unknown_on_eperm
      omit 'root では EPERM にならない' if Process.uid.zero?
      omit '触れない他ユーザーのプロセスが見つからない' unless (pid = foreign_pid)

      assert_equal(:unknown, Process.alive_state(pid))
      # 述語としては false 側に落ちるが、:dead ではない。
      assert_false(Process.alive?(pid))
    end

    # ⚠ pid として解釈できない引数でも例外を投げない契約は保つ。
    # ⚠ ただし「死んでいる」とは答えない。
    def test_alive_state_unknown_on_garbage
      assert_equal(:unknown, Process.alive_state('not a pid'))
      assert_equal(:unknown, Process.alive_state(nil))
    end

    private

    # 使われていない pid。⚠ 取り違えると :dead の検証にならないので、実際に
    # 存在しないことを確かめてから返す。
    def unused_pid
      (2**15).downto(2) do |pid|
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return pid
      rescue Errno::EPERM # rubocop:disable Lint/SuppressedException
      end
      return nil
    end

    # 自分では触れない他ユーザーのプロセス。init (1) が典型だが、コンテナ等では
    # 自分のものであることもあるので、EPERM になるものを探す。
    def foreign_pid
      [1, 2].each do |pid|
        Process.kill(0, pid)
      rescue Errno::EPERM
        return pid
      rescue StandardError # rubocop:disable Lint/SuppressedException
      end
      return nil
    end
  end
end
