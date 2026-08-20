# frozen_string_literal: true

module Ginseng
  class Daemon
    include Package

    attr_reader :pid_file, :working_dir, :app_name

    def initialize(opts = {})
      @logger = logger_class.new
      @config = config_class.instance
      @app_name = opts[:application] || classname
      @working_dir = opts[:working_dir] || environment_class.dir
      @pid_file = File.join(@working_dir, 'tmp', 'pids', "#{@app_name}.pid")
    end

    def name
      return self.class.to_s.split('::').last.sub(/Daemon$/, '').underscore
    end

    def classname
      return self.class.to_s.split('::').last
    end

    def start(args = [])
      save_config
      @logger.info(
        daemon: app_name,
        version: package_class.version,
        message: 'start',
        command: command.to_s,
      )
      exec(command.to_s)
    end

    def stop
      @logger.info(daemon: app_name, version: package_class.version, message: 'stop')
      Process.kill('TERM', 0)
    end

    def command
      raise ImplementError, "'#{__method__}' not implemented"
    end

    def motd
      return self.class.to_s
    end

    def jit?
      return environment_class.jit?
    end

    alias jit_ready? jit?

    def pid
      return File.read(pid_file).to_i if File.file?(pid_file)
      return nil
    rescue Errno::ENOENT
      # ⚠⚠ **読む直前に消えることがある (#561)。** 相手の trap が消した直後で、
      # 「無い」と同じ意味なので nil に倒す。🔴 ここで例外を上げると
      # `run_restart` が `run_stop` の途中で抜け、**止めただけで後継を fork しない**。
      return nil
    end

    # pid ファイルが指すプロセスの状態。:alive / :dead / :unknown (#510)。
    #
    # ⚠ **:unknown を :dead と同じに扱わないこと。** `EPERM` は「プロセスは
    # 存在するが触れない」なので、:dead と混ぜると **start が 2 本目を立て、
    # 1 本目がどの pid ファイルからも辿れない孤児になる**。
    def alive_state
      return :dead unless (p = pid)
      return Process.alive_state(p)
    end

    # ⚠ **既存の呼び出し側のために真偽 2 値のまま残す**（:unknown は false 側）。
    # 「起動していいか」「止めていいか」の判断には alive_state を使うこと。
    def alive?
      return alive_state == :alive
    end

    def save_config
      config = @config.raw['application'][name]
      if values = @config.raw['local']&.dig(name)
        config.deep_merge!(values)
      end
      File.write(config_cache_path, config.to_yaml)
    end

    def config_cache_path
      return File.join(environment_class.dir, "tmp/cache/#{name}.yaml")
    end

    def self.spawn!(opts = {}, args = ARGV)
      daemon = new(opts)
      case args.any? && args.shift
      when 'start'
        daemon.send(:run_start, args)
      when 'stop'
        daemon.send(:run_stop)
      when 'restart'
        daemon.send(:run_restart, args)
      when 'status'
        daemon.send(:run_status)
      else
        warn "Usage: #{$PROGRAM_NAME} start|stop|restart|status"
        exit 1
      end
    end

    private

    def write_pid
      File.write(pid_file, Process.pid.to_s)
    end

    # ⚠⚠ **自分が知っている pid のままのときだけ消す (#532)。**
    #
    # 相手が `TERM` を先に処理して**自分の trap で pid ファイルを消し**、
    # supervisor が後継を起動して**新しい pid を書いた**あとに、こちらの
    # `remove_pid` が走ると、**後継の pid ファイルを消す**。🔴 後継はどの pid
    # ファイルからも辿れなくなり、次の `start` が 2 本目を立てる — #509 で塞いだ
    # 「停止コマンド自身が孤児を作る」の、別のレースとしての再現。
    #
    # ⚠ **読んでから消すまでの隙間は残る。** 完全に閉じるには削除の責任を 1
    # プロセスへ寄せる必要があり、それは別の設計判断（#532 に記録）。
    def remove_pid(expected = nil)
      return FileUtils.rm_f(pid_file) if expected.nil?
      return unless pid == expected
      FileUtils.rm_f(pid_file)
    end

    # ⚠ **テストのための継ぎ目**。EPERM / ESRCH のときの pid ファイルの扱い (#509)
    # は実プロセスへシグナルを送らずに確かめたい（他人のプロセスへ TERM を送る
    # テストは書けない）。
    def send_signal(signal, pid)
      Process.kill(signal, pid)
    end

    # ⚠ **:unknown でも起動しない** (#509 / #510)。pid ファイルが指すプロセスに
    # 触れないだけで、生きている可能性がある。ここで通すと 2 本目が立ち、
    # 1 本目が孤児になる。
    def abort_if_running!
      case alive_state
      when :alive
        warn "#{app_name} is already running (PID #{pid})"
        exit 1
      when :unknown
        warn "PID '#{pid}' exists but is not ours. Not starting #{app_name}."
        exit 1
      end
    end

    def run_start(args = [])
      abort_if_running!
      puts motd
      write_pid
      # ⚠ 自分の pid ファイルだけを消す (#532)。後継が書き直していたら触らない。
      trap('TERM') do
        remove_pid(Process.pid)
        stop
        exit
      end
      trap('INT') do
        remove_pid(Process.pid)
        stop
        exit
      end
      start(args)
    end

    # ⚠ **シグナルを送ってから pid ファイルを消すこと** (#509)。
    #
    # 逆順にすると、`Errno::EPERM`（シグナルを送る権限が無い）のときに
    # **プロセスは生きたまま・pid ファイルだけ消える**。次の start は「未起動」と
    # 判断して 2 本目を立て、1 本目はどの pid ファイルからも辿れない孤児になる。
    # ⚠ **停止コマンド自身が孤児を作る**という形だった。
    def run_stop
      unless (p = pid)
        warn 'PID file not found. Is the daemon started?'
        exit 1
      end
      send_signal('TERM', p)
      # ⚠ **後継の pid ファイルを消さない (#532)。** 中身がまだ p のときだけ消す。
      remove_pid(p)
    rescue Errno::ESRCH
      # 既に居ないので pid ファイルは消してよい（⚠ ただし中身が p のときだけ）。
      remove_pid(p)
      warn 'PID file found, but process was not running.'
    rescue Errno::EPERM
      # ⚠ **pid ファイルは残す。**消すと生きたままのプロセスが辿れなくなる。
      warn "PID '#{p}' is not ours. Not stopping #{app_name}."
      exit 1
    end

    def run_restart(args = [])
      # ⚠ **:unknown でも止めにいく** (#510)。ここを alive? で切ると、EPERM の
      # ときに停止を飛ばしたまま start へ進んで 2 本目が立つ。
      run_stop unless alive_state == :dead
      sleep 1
      child = fork do
        Process.setsid
        $stdout.reopen(File::NULL, 'w')
        $stderr.reopen(File::NULL, 'w')
        run_start(args)
      end
      Process.detach(child)
    end

    # ⚠ **「触れなかった」を「動いていない」と表示しない** (#510)。運用者が
    # 自分のユーザーで叩いたときに、動いているのに not running と出る形だった。
    def run_status
      case alive_state
      when :alive
        puts "#{app_name} is running (PID #{pid})"
      when :unknown
        puts "#{app_name}: PID #{pid} exists but is not ours (unknown)"
      else
        puts "#{app_name} is not running"
      end
    end
  end
end
