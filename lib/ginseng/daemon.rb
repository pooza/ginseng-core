# frozen_string_literal: true

module Ginseng
  class Daemon
    include Package

    # ⚠ pid ファイルの取得・保持・後始末は別ファイルへ出してある (#627)。
    # **混ぜる側が `pid_file` / `app_name` / `@logger` を持つ前提**は変わらないので、
    # 利用側の見え方（`write_pid` を override する、など）は同じ。
    include PidFile

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

    # pid ファイルが指すプロセスの状態。:alive / :dead / :unknown (#510)。
    #
    # ⚠ **:unknown を :dead と同じに扱わないこと。** `EPERM` は「プロセスは
    # 存在するが触れない」なので、:dead と混ぜると **start が 2 本目を立て、
    # 1 本目がどの pid ファイルからも辿れない孤児になる**。
    def alive_state
      reset_pid_file_error
      found = pid
      return Process.alive_state(found) if found
      # ⚠⚠ **読めないファイルが在るなら「無い」ではない (#627 Codex P2)。**
      # 🔴 :dead と答えると `run_status` が「動いていない」と嘘をつき、
      # `run_restart` が停止を飛ばす。**触れないだけで生きている可能性がある**
      # ので :unknown に倒す（#510 と同じ理由）。
      return :unknown if pid_file_unreadable?
      return :dead
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

    # ⚠ **テストのための継ぎ目**。EPERM / ESRCH のときの pid ファイルの扱い (#509)
    # は実プロセスへシグナルを送らずに確かめたい（他人のプロセスへ TERM を送る
    # テストは書けない）。
    def send_signal(signal, pid)
      Process.kill(signal, pid)
    end

    # ⚠ **:unknown でも起動しない** (#509 / #510)。pid ファイルが指すプロセスに
    # 触れないだけで、生きている可能性がある。ここで通すと 2 本目が立ち、
    # 1 本目が孤児になる。
    #
    # ⚠⚠ **これは早期の診断であって、start 同士のレースは閉じない (#622)。**
    # 閉じているのは `write_pid` の `O_EXCL`。🔴 **ここを通ったことを「取れた」と
    # 読まないこと。**
    def abort_unreadable_pid_file!(error)
      abort_start!("PID file '#{pid_file}' exists but could not be read.",
        'pid file unreadable', error)
    end

    def abort_if_running!
      reset_pid_file_error
      # 🔴🔴 **読めなかったときは、サブクラスの `alive_state` に訊く前に拒む (#635)。**
      # ⚠⚠ **`pid` は「無い」も「読めない」も nil に畳む**ので、上書き側が
      # `pid&.positive?` で判定していると**「読めない」が :dead に化ける** — そこから
      # 生きている常駐の pid ファイルを奪いにいける。⚠ 上流でここを閉じておけば、
      # 利用側が見落としても二重起動には届かない。
      # ⚠⚠ **読むのはここだけ。以降は持ち回る (#635 Codex P2)。** 🔴 メッセージを
      # 組み立てる途中で読み直すと、**記録してあった errno が消え**、一過性の失敗なら
      # 番号入りの矛盾したメッセージにもなる。
      found = pid
      error = pid_file_error
      state = alive_state
      # ⚠⚠ **`alive_state` も pid ファイルを読む。** どちらの読み取りで失敗しても
      # 🔴 **状態は決められていない** — :dead / :alive と答えられていても起動しない。
      # ⚠ `alive_state` は入口でもあり記録を消すので、**呼ぶ前に受け取っておく**。
      error ||= pid_file_error
      current = pid
      error ||= pid_file_error
      abort_unreadable_pid_file!(error) if error
      # ⚠⚠ **検査のあいだに変わったなら番号を名乗らない (#635 Codex P2・7 巡目)。**
      # 状態は新しい方を、番号は古い方を指すため。⚠ **拒むこと自体は変わらない。**
      found = nil if current != found
      case state
      when :alive
        # ⚠ **番号が無いなら場所を出す**（🔴 `(PID )` にしない）。
        abort_start!("#{app_name} is already running (#{pid_label(found)}).", 'already running',
          nil)
      when :unknown
        abort_start!("#{pid_label(found)} exists but is not ours.", 'pid file is not ours', nil)
      end
    end

    def run_start(args = [])
      # ⚠ 早期に理由を出すためのもの。**取得そのものは write_pid が原子的に行う** (#622)。
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
      reset_pid_file_error
      unless (p = pid)
        # ⚠⚠ **「無い」と「読めない」を言い分ける (#635)。** 🔴 読めないだけのときに
        # 「PID file not found」と言うのは**嘘**で、しかもそこで無音のまま終わると
        # `restart` が「起動を試みる前に」消える。
        if pid_file_unreadable?
          abort_stop!("PID file '#{pid_file}' exists but could not be read.", 'pid file unreadable')
        end
        abort_stop!('PID file not found. Is the daemon started?', 'pid file not found')
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
      abort_stop!("PID '#{p}' is not ours.", 'pid file is not ours')
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
      reset_pid_file_error
      found = pid
      # ⚠⚠ **番号と状態は同じ読み取りから出す (#635 Codex P2)。** 🔴 別々に読むと、
      # 片方だけ失敗したときに `is running (PID )` のような壊れた行になる。
      error = pid_file_error
      state = alive_state
      # ⚠⚠ **`alive_state` は入口でもあるので記録を消す。** 🔴 だから**呼ぶ前に
      # 受け取っておく**（持ち越しは `alive_state` の内側でだけ効く）。
      error ||= pid_file_error
      current = pid
      # ⚠⚠ **検証の読み取り自身の失敗も見る。** 🔴 失敗すると `nil` が返り、
      # 「変わった」にも「変わっていない」にも化ける (#635 Codex P2・7 巡目)。
      error ||= pid_file_error
      return puts "#{app_name}: PID file '#{pid_file}' could not be read" if error
      # 🔴🔴 **検査のあいだに中身が変わったら、番号と状態は別のプロセスを指す
      # (#635 Codex P2・6 巡目)。** ⚠⚠ 別の start が死んだ pid を奪って自分のものを
      # 書いた場合、**`alive_state` は新しい方を見て `:alive`、番号は古い方**になり、
      # **死んだ番号を「動いている」と報告する**。⚠ `alive_state` は利用側の上書き点で
      # 引数を取れないので、**変わっていないことを確かめる**側で閉じる。
      return puts "#{app_name}: PID file changed while checking (unknown)" if current != found
      # ⚠ 読めたのに番号が無い（2 つの読み取りの間にファイルが現れた）なら、分からない。
      state = :unknown if state == :alive && found.nil?
      case state
      when :alive
        puts "#{app_name} is running (PID #{found})"
      when :unknown
        puts "#{app_name}: #{pid_label(found)} exists but is not ours (unknown)"
      else
        puts "#{app_name} is not running"
      end
    end
  end
end
