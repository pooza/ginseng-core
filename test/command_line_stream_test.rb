# frozen_string_literal: true

require 'tempfile'

module Ginseng
  # `exec(io:)`（実行しながら出力を流す・#745）。
  class CommandLineStreamTest < TestCase
    # 書かれた行と、書かれた時刻を控える流し先。
    class Recorder
      attr_reader :lines, :times

      def initialize
        @lines = []
        @times = []
      end

      def write(line)
        @lines.push(line)
        @times.push(Process.clock_gettime(Process::CLOCK_MONOTONIC))
        return line.bytesize
      end
    end

    # 最初の書き込みで壊れる流し先（閉じた端末・読み手のいないパイプ）。
    class BrokenSink
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def write(_line)
        @calls += 1
        raise Errno::EPIPE
      end
    end

    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @command = CommandLine.new
      @sink = Recorder.new
    end

    # ⚠⚠ **ここの芯。** 終わってから流すのでは意味が無い。最初の行が、コマンドが終わる
    # （1 秒眠る）より前に届くことを測る。
    def test_exec_streams_while_running
      {exec: {}, exec_with_timeout: {timeout: 10}}.each do |name, options|
        sink = Recorder.new
        @command.args = ['sh', '-c', 'echo first; sleep 1; echo second']
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_equal(0, @command.exec(io: sink, **options))
        finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_equal(["first\n", "second\n"], sink.lines, name)
        assert_operator(sink.times.first - started, :<, 0.5, name)
        assert_operator(finished - sink.times.first, :>, 0.5, name)
      end
    end

    def test_exec_streams_both_pipes_and_keeps_them
      @command.args = ['sh', '-c', 'echo out; echo err >&2; printf tail']

      assert_equal(0, @command.exec(io: @sink))
      assert_equal(["err\n", "out\n", 'tail'], @sink.lines.sort)
      assert_equal("out\ntail", @command.stdout)
      assert_equal("err\n", @command.stderr)
      assert_kind_of(Integer, @command.pid)
    end

    # ⚠ 流さないときと同じ値を持つこと（符号化も）。
    def test_exec_keeps_the_same_result_as_without_io
      @command.args = ['sh', '-c', 'printf "\\343\\201\\202\\n"; printf "\\377\\n" >&2; exit 3']
      @command.exec
      plain = [@command.stdout, @command.stderr, @command.status]

      # ⚠ `status` は `Process::Status#to_i`（生の値・exit 3 は 768）。流さないときと同じ。
      assert_equal(plain[2], @command.exec(io: @sink))
      assert_not_equal(0, plain[2])
      assert_equal(plain, [@command.stdout, @command.stderr, @command.status])
      assert_equal(plain[0].encoding, @command.stdout.encoding)
    end

    # ⚠⚠ 両方のパイプを同時に読むこと。片方ずつだと、stderr が埋まった時点で止まる。
    def test_exec_streams_large_stderr_without_deadlock
      @command.args = ['sh', '-c', 'head -c 300000 /dev/zero | tr "\\0" a >&2; echo ok']

      # ⚠ 締切の無い経路（`capture_streaming`）と、締切の経路（`Deadline`）は別の実装。
      [{}, {timeout: 10}].each do |options|
        sink = Recorder.new

        # 🔴 詰まると戻らない。止まったまま件数だけ減って緑に見えないよう、待つ上限を切って落とす。
        runner = Thread.new {@command.exec(io: sink, **options)}

        assert(runner.join(30), "stuck reading the pipes #{options.inspect}")
        assert_equal(0, runner.value, options.inspect)
        assert_equal("ok\n", @command.stdout)
        assert_equal(300_000, @command.stderr.bytesize)
        assert_equal(300_000 + 3, sink.lines.sum(&:bytesize))
      end
    end

    # 🔴 締切は流しているときも効く。締切までに流した分は流し先に残る。
    def test_exec_timeout_stops_a_streaming_child
      @command.args = ['sh', '-c', 'echo first; exec sleep 30']
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raise(Timeout::Error) {@command.exec(timeout: 1, io: @sink)}
      assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5)
      assert_equal(["first\n"], @sink.lines)
      assert_nil(@command.status)
    end

    # 🔴 流す行は `secrets=` の値を伏せる。`stdout` は伏せない。
    def test_exec_masks_secrets_in_the_stream
      @command.secrets = ['s3cret']
      @command.args = ['sh', '-c', 'echo token=s3cret']

      assert_equal(0, @command.exec(io: @sink))
      assert_equal(["token=#{Masking::FILTERED}\n"], @sink.lines)
      assert_equal("token=s3cret\n", @command.stdout)
    end

    # ⚠ 不正なバイト列の行でも、伏せる処理で落ちない。
    def test_exec_masks_a_line_with_invalid_bytes
      @command.secrets = ['s3cret']
      @command.args = ['sh', '-c', 'printf "\\377 s3cret\\n"']

      assert_equal(0, @command.exec(io: @sink))
      assert_equal(1, @sink.lines.size)
      assert_not_include(@sink.lines.first.b, 's3cret')
    end

    # 🔴 流し先が壊れても、コマンドも受け取りも止めない。warn を 1 行残す。
    def test_exec_keeps_reading_when_the_sink_breaks
      sink = BrokenSink.new
      logger = Logger.new
      warned = []
      logger.define_singleton_method(:warn) {|message = nil| warned.push(message)}
      @command.instance_variable_set(:@logger, logger)
      @command.args = ['sh', '-c', 'for i in 1 2 3 4 5; do echo $i; done']

      assert_equal(0, @command.exec(io: sink))
      assert_equal("1\n2\n3\n4\n5\n", @command.stdout)
      assert_equal(1, sink.calls)
      assert_equal(1, warned.size)
      assert_equal('Errno::EPIPE', warned.first[:error])
    end

    # ⚠ 受け取る側で検査する。`write` を持たないものは、子を起こす前に拒む。
    def test_exec_rejects_io_without_write
      Tempfile.create('ginseng_745') do |file|
        @command.args = ['sh', '-c', "echo ran > #{file.path}"]

        assert_raise(ArgumentError) {@command.exec(io: true)}
        assert_empty(File.read(file.path))
      end
    end

    # ⚠⚠ 写しに届いていなかった直し（#480 / #710 の環境）が、流す経路にも効くこと。
    def test_exec_streaming_child_sees_the_unbundled_env
      assert_predicate(ENV.fetch('BUNDLE_GEMFILE', nil), :present?, '前提: 親は bundler の下で動いている')
      @command.env = {'GINSENG_TEST_745' => 'given'}
      @command.args = ['sh', '-c', 'echo "${BUNDLE_GEMFILE-unset} ${GINSENG_TEST_745-unset}"']
      [{}, {timeout: 10}].each do |options|
        sink = Recorder.new
        @command.exec(io: sink, **options)

        assert_equal(["unset given\n"], sink.lines, options.inspect)
      end
    end

    def test_exec_streams_with_dir
      @command.dir = '/etc'
      @command.args = ['pwd']

      assert_equal(0, @command.exec(io: @sink))
      assert_equal(["/etc\n"], @sink.lines)
    end
  end
end
