# frozen_string_literal: true

module Ginseng
  class Daemon
    include Package

    # pid ファイルを取り直す回数 (#622)。⚠ **死んだ pid ファイルを剥がして作り直す
    # のは 1 回で足りる**が、剥がした直後に別の start に勝たれることがあるので少し
    # 余裕を持たせる。⚠⚠ **無制限にはしない** — 回り続けるより起動しないほうが安全
    # （こちらが待っている間に 2 本目が立つ形を作らない）。
    PID_ACQUIRE_ATTEMPTS = 3

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

    # pid ファイルを**原子的に**取得する。取れなければ起動しない (#622)。
    #
    # 🔴 **`abort_if_running!` → `write_pid` の 2 段では閉じない。** pid ファイルが
    # 書かれるのはプロセスの起動から数秒後（`bundle exec` のブート）なので、
    # ⚠⚠ **その窓に入った 2 本目も「未起動」と判断してすり抜ける**。両方が起動し、
    # 後から書いた方だけが pid ファイルに残るので、**先の 1 本はどの pid ファイル
    # からも辿れない孤児になる** — #509 / #510 / #532 で潰したのと同じ結末の、
    # **start 同士のレース**。⚠ 実例は pooza/mulukhiya-toot-proxy#4675（sidekiq が
    # 2 本立ち、スケジュール登録された全ワーカーが毎サイクル二重投入された）。
    #
    # ⚠⚠ **`O_EXCL` は「無ければ作る」を原子的に行う**ので、勝てるのは 1 本だけになる。
    # ⚠ **`O_EXCL` だけだと異常終了で残った pid ファイルが起動を永久に阻む**ので、
    # **死んでいると断定できたときに限って**奪う（🔴 **:unknown では奪わない**。
    # 触れないだけで生きている可能性がある — #510）。⚠⚠ **奪うときに消さない** —
    # 理由は `reclaim_pid_file`。
    #
    # ⚠ **ここは利用側の override 点でもある**（pid が外から見えるより前に trap を
    # 張る、など）。**`super` を呼ぶ形は保つこと。**
    def write_pid
      PID_ACQUIRE_ATTEMPTS.times do
        return if create_pid_file
        # ⚠ **判断より先に読む。** 読んだあとで中身が変わっていたら奪わない
        # （reclaim_pid_file がロックの中で読み直す）。
        stale = pid
        # ⚠⚠ **自分が既に取っているなら取得済み。** ここを通さないと、同じプロセスから
        # 2 度呼ばれたときに**自分の pid を見て「already running」で終了する**。
        return if stale == Process.pid
        # ⚠ **:alive / :unknown はここで終わる。** サブクラスが上書きした
        # alive_state を通すために、pid を渡さずこちらを呼ぶ。
        abort_if_running!
        # 🔴🔴 **空の pid ファイルは「取得の途中」であって stale ではない
        # (#622 Codex P1)。** `O_EXCL` に勝った 1 本が、まだ pid を書いていない状態。
        # ⚠⚠ **`File.read('').to_i` は `0` を返し、`0` は truthy** なので、
        # `alive_state` を上書きしている利用側（非正の pid を :dead と読む）では
        # **奪えてしまい、2 本とも起動する**。⚠ 読む直前に消えた場合 (#561) も同じ扱い。
        next unless stale&.positive?
        return if reclaim_pid_file(stale)
      end
      warn "Could not acquire PID file '#{pid_file}'. Not starting #{app_name}."
      exit 1
    end

    # 死んだ pid ファイルを**消さずに**奪う。奪えたら true。
    #
    # 🔴🔴 **「消して作り直す」にしないこと (#622 Codex P1)。** `remove_pid` は
    # 「中身を読む → `rm_f`」の 2 段なので、⚠⚠ **2 本が同じ stale を見ると両方が
    # 検査を通る**。片方が消して `O_EXCL` で作った直後に、もう片方の `rm_f` が
    # **その新しい pid ファイルを消す** — 先に勝った 1 本が pid ファイルを失い、
    # 次の start が 2 本目を立てる。**この PR が閉じたい形そのものに戻る。**
    #
    # ⚠ **ファイルの同一性を変えない**（unlink しない）ので、消される相手が居ない。
    # `flock` を取れた 1 本だけが**中身を差し替えて**持ち主になる。⚠⚠ **ロックを
    # 取ってから読み直す** — 待っている間に別の start が奪っていることがある。
    def reclaim_pid_file(stale)
      # ⚠ **呼ぶ側に頼らない。** 非正の pid は「取得の途中」で、奪う相手ではない。
      return false unless stale.positive?
      File.open(pid_file, File::RDWR) do |f|
        return false unless f.flock(File::LOCK_EX | File::LOCK_NB)
        return false unless f.read.to_i == stale
        f.rewind
        f.write(Process.pid.to_s)
        f.flush
        f.truncate(f.pos)
        return true
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
      # ⚠ 開く直前に消えた (#561)か、別ユーザーが残していて書けないか。
      # ⚠⚠ **どちらも例外のまま抜けない** — 🔴 backtrace だけが出て、運用者には
      # 理由が伝わらない。消えていたなら次の周回で作り直し、書けないなら取り直しの
      # 回数を使い切って下の warn に落ちる。
      return false
    end

    # ⚠⚠ **`File.write` にしないこと (#622)。** あれは在っても上書きするので、
    # 「無ければ作る」の原子性が無い。
    def create_pid_file
      File.open(pid_file, File::WRONLY | File::CREAT | File::EXCL) do |f|
        # ⚠ **書く側は必ずロックを取る。** 取らないと、奪いに来た側が
        # **書きかけの中身**を読む（reclaim_pid_file はロックの中で読み直す）。
        f.flock(File::LOCK_EX)
        f.write(Process.pid.to_s)
      end
      return true
    rescue Errno::EEXIST
      return false
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
    #
    # ⚠⚠ **これは早期の診断であって、start 同士のレースは閉じない (#622)。**
    # 閉じているのは `write_pid` の `O_EXCL`。🔴 **ここを通ったことを「取れた」と
    # 読まないこと。**
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
