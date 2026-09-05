# frozen_string_literal: true

module Ginseng
  class Daemon
    include Package

    # pid ファイルの取得を試みる回数 (#622)。⚠ **負け方が 4 通りあるので 1 回では
    # 足りない** — ①`O_EXCL` の作成が `EEXIST` ②奪おうとして `flock` が取れない
    # ③ロックの中で読み直したら中身が変わっていた ④作成には勝ったが `flock` の前に
    # 奪われて自分から負けを認めた。いずれも「読み直せば決着がつく」ので少しだけ回す。
    # ⚠⚠ **無制限にはしない** — 回り続けるより起動しないほうが安全（こちらが待って
    # いる間に 2 本目が立つ形を作らない）。
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

    # pid ファイルが指す pid。⚠ **pid として読めたときだけ返す** (#627)。
    #
    # 🔴🔴 **`to_i` の結果をそのまま返さないこと。** 空のファイルも壊れたファイルも
    # `0` になり、⚠⚠ **`0` は truthy なうえ `Process.kill(0, 0)` は自分のプロセス
    # グループ宛てなので成功する**。帰結は 2 つとも重い —
    # **`run_start` は `already running (PID 0)` で無言終了**（supervisor が叩き直しても
    # 永久に起動しない）、**`run_stop` は `TERM` を呼び出し元のプロセスグループ全体へ**。
    #
    # ⚠ **nil に倒してよいのは、`write_pid` が「pid として読めない中身」を
    # 見捨てられたものとして奪えるから** (#622)。奪う側は中身の同一性をロックの中で
    # 確かめ、作る側は奪われていたら書かずに負けを認めるので、二重起動にならない。
    def pid
      return nil unless (value = read_pid_file)
      return nil unless (value = value.to_i).positive?
      return value
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
    # ⚠⚠ **pid として読めない中身（空・壊れている）は例外で、生死を訊かずに奪う。**
    # 訊く相手が居ないため。奪ってよい根拠は `create_pid_file` の「負け認め」で、
    # 🔴 **奪われた側が書き戻さないので二重起動にならない**。
    #
    # ⚠ **ここは利用側の override 点でもある**（pid が外から見えるより前に trap を
    # 張る、など）。**`super` を呼ぶ形は保つこと。**
    def write_pid
      PID_ACQUIRE_ATTEMPTS.times do
        return if create_pid_file
        # ⚠ **解釈する前の中身を覚える。** 奪うときに**ロックの中で同じものか**を
        # 確かめるので、`to_i` した結果では足りない（🔴 空と `'0'` と `'abc'` が
        # 同じ `0` になる）。
        observed = read_pid_file
        # ⚠ 読む直前に消えることがある (#561)。作り直しから試す。
        next if observed.nil?
        # ⚠⚠ **自分が既に取っているなら取得済み。** ここを通さないと、同じプロセスから
        # 2 度呼ばれたときに**自分の pid を見て「already running」で終了する**。
        return if observed.to_i == Process.pid
        # 🔴 **pid として読めない中身に生死を訊かない。** 空・非正の中身は訊く相手が
        # 居ない — 既定では `Process.kill(0, 0)` が成功して :alive、`alive_state` を
        # 上書きしている利用側では :dead と、**答えが実装で割れる** (#627)。
        # ⚠ 奪ってよいかは、この下の `reclaim_pid_file` がロックの中で決める。
        abort_if_running! if observed.to_i.positive?
        return if reclaim_pid_file(observed)
      end
      abort_start!("Could not acquire PID file '#{pid_file}'.", 'could not acquire pid file')
    end

    # 起動しなかったことを **stderr と logger の両方**に出して終わる。
    #
    # 🔴🔴 **stderr だけでは `restart` で消える（リリース前レビューの赤）。**
    # `run_restart` は fork した子の stdout / stderr を自分で `File::NULL` へ
    # 付け替えるので、⚠⚠ **「起動しなかった」ことがどこにも残らないまま、親は
    # exit 0 で返る**。supervisor は叩き直し続け、**落ちているのにログが 1 行も
    # 増えない**という形になる。
    def abort_start!(message, reason)
      warn "#{message} Not starting #{app_name}."
      @logger.error(daemon: app_name, version: package_class.version,
        message: 'not started', reason:, pid_file:)
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
    # 取ってから読み直す** — 🔴 **自分が中身を読んでから `flock` を取るまでの間**に
    # 別の start が奪っていることがある（⚠ ロックは `LOCK_NB` なので待たない）。
    def reclaim_pid_file(observed)
      File.open(pid_file, File::RDWR) do |f|
        return false unless f.flock(File::LOCK_EX | File::LOCK_NB)
        # ⚠⚠ **ロックを取ってから読み直す。** 自分が読んでからここへ来るまでに
        # 別の start が奪っていれば、それはもう自分が見たファイルではない。
        return false unless f.read == observed
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
      File.open(pid_file, File::RDWR | File::CREAT | File::EXCL) do |f|
        # ⚠ **書く側は必ずロックを取る。** 取らないと、奪いに来た側が
        # **書きかけの中身**を読む（reclaim_pid_file はロックの中で読み直す）。
        return false unless lock_pid_file(f)
        # 🔴🔴 **作成から flock までの隙間で奪われていたら、書かずに負けを認める
        # (#622 Codex P1)。** ⚠⚠ **この 1 行があるから、空のファイルを「見捨てられた」
        # と読んで奪ってよくなる** — 奪われた側が上書きし返さないので、2 本とも
        # 起動する形にならない。⚠ 負けたことは呼ぶ側が次の周回で読み直して知る。
        return false unless f.read.empty?
        f.rewind
        f.write(Process.pid.to_s)
      end
      return true
    rescue Errno::EEXIST
      return false
    end

    # ⚠ **テストのための継ぎ目**。「作成には勝ったが flock はまだ」という瞬間に
    # 別の start が奪う状況は、実プロセスを並べても順序を握れないので作れない。
    #
    # ⚠⚠ **`LOCK_NB` で待たない。** 🔴 待つ形にすると、隙間に外部プロセスが同じ
    # inode の `LOCK_EX` を握ったときに**無限に待つ**（そのあいだ pid ファイルは
    # 空のまま公開されている）。取れなければ次の周回へ回して、最後は「取れなかった」
    # で終わる — **ハングより起動しないほうがよい**。
    def lock_pid_file(file)
      return file.flock(File::LOCK_EX | File::LOCK_NB)
    end

    # pid ファイルの中身を**解釈せずに**返す。無ければ nil。
    #
    # ⚠ `pid` は `to_i` した結果しか返さないので、🔴 **空と `'0'` と壊れた中身が
    # 区別できない**。奪うときの「同じものか」の判定にはこちらを使う。
    def read_pid_file
      return File.read(pid_file) if File.file?(pid_file)
      return nil
    rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
      # ⚠⚠ **読む直前に消えることがある (#561)。** 相手の trap が消した直後で、
      # 「無い」と同じ意味なので nil に倒す。🔴 ここで例外を上げると
      # `run_restart` が `run_stop` の途中で抜け、**止めただけで後継を fork しない**。
      #
      # ⚠ **別ユーザーが残していて読めない場合も nil。** 🔴 例外のまま抜けると
      # backtrace だけが出て、運用者には理由が伝わらない。⚠⚠ **読めない ＝ 触れない
      # ので、後続の `create_pid_file` / `reclaim_pid_file` がどちらも失敗し、
      # 「取れなかった」と言って終わる**（起動はしない）。
      return nil
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
        abort_start!("#{app_name} is already running (PID #{pid}).", 'already running')
      when :unknown
        abort_start!("PID '#{pid}' exists but is not ours.", 'pid file is not ours')
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
