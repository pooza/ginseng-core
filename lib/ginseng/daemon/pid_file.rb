# frozen_string_literal: true

require 'securerandom'

module Ginseng
  class Daemon
    # pid ファイルの取得・保持・後始末の一式 (#622 / #627)。⚠ `Daemon` から切り出して
    # ある — **`Daemon` に混ぜて使う前提**で、`pid_file` / `app_name` / `@logger` は
    # 混ぜた側が持つ。
    #
    # 🔴🔴 **この一式の芯は「確認と書き込みを 1 つの排他の中で行う」こと。**
    # 分けて書くと、pid ファイルが書かれるまでの数秒（`bundle exec` のブート）に
    # 入った 2 本目も「未起動」と判断してすり抜け、⚠⚠ **後から書いた方だけが pid
    # ファイルに残るので、先の 1 本はどの pid ファイルからも辿れない孤児になる**
    # （実例: pooza/mulukhiya-toot-proxy#4675）。
    #
    # ⚠⚠ **排他は pid ファイルではなく、消さないロック専用ファイルの `flock` で取る**
    # (#643)。pid ファイルそのものは、自分が作った一時ファイルを `rename` して置き換える。
    # 既存の inode に書かないので、経路をすり替えられても別のファイルは壊れない
    # （→ `replace_pid_file`）。
    module PidFile
      include PidLock

      # pid ファイルの取得を試みる回数と、周回の間の待ち（秒） (#622 / #643)。負け方は 2 通り —
      # ①ロック専用ファイルの `flock` が取れない（別の start が判断している最中）
      # ②判断しているあいだに pid ファイルの中身が変わった（ロックを取らない書き手が居る）。
      # どちらも読み直せば決着がつくので、合計 1 秒ほど回す。
      # 🔴 **待ちを外さないこと**（リリース前レビュー）。待たずに回すと、同時に start した
      # 負け側は勝ち側がロックを握っている数 ms で周回を使い切り、「already running」ではなく
      # 原因の読めない「Could not acquire」で終わる（6 本同時で 4 本がそうなった）。
      # ⚠⚠ **無制限にはしない** — 回り続けるより起動しないほうが安全。
      PID_ACQUIRE_ATTEMPTS = 10
      PID_ACQUIRE_WAIT_SECONDS = 0.1

      # ⚠ 以下の 3 つは `parse_pid` が**この順で**当てる（量 → 形 → 番号）。

      # 読む上限 (#629)。pid ファイルに入ってよいのは数桁と改行だけなので、壊れた
      # ファイルや細工されたファイルを丸ごとメモリへ載せない。
      # ⚠⚠ **奪うときの読み直しにも同じ上限を使う** — 違う長さで読むと、同じ中身が
      # 「変わった」に見えて永久に奪えなくなる。
      # ⚠ **読むのは上限より 1 バイト多い**（超えていることを知るため）。
      PID_FILE_MAX_BYTES = 64

      # pid ファイルに書かれてよい形。10 進の数字だけ（`\d` は ASCII なので全角は
      # 入らない）。⚠⚠ **`Integer()` に任せない** — `'12_34'`（桁区切り）や `'+123'`
      # が通る。
      PID_PATTERN = /\A\d+\z/

      # 番号としての上限 (#629)。`pid_t` は 32bit 符号付きなので、これを超えると
      # `Process.kill` が `RangeError` を上げ、`Process.alive_state` はそれを
      # `:unknown` に丸める。⚠⚠ **そうなると `abort_if_running!` が毎回起動を拒み、
      # `write_pid` が奪って復帰する機会が来ない** — この上限が防ごうとしている
      # 「永久に起動できない」そのものになる。⚠ **桁数では切れない**（`9999999999`
      # は 10 桁だが範囲外）。
      PID_MAX = (2**31) - 1

      # pid を書く一時ファイルを作るときの旗 (#643)。
      #
      # ⚠⚠ **`O_EXCL` がこの設計の芯。** 書くのは、いま自分が作った inode だけになる。
      # `O_CREAT | O_EXCL` は最終要素の symlink も `EEXIST` で拒むが、`O_NOFOLLOW` も重ねておく
      # （`O_EXCL` を外す変更が入っても、symlink の先には書かない）。
      PID_TEMP_OPEN_FLAGS = File::WRONLY | File::CREAT | File::EXCL | NOFOLLOW_FLAG

      # 読むときの open の旗。⚠⚠ **`O_NONBLOCK` が要る** — pid ファイルの位置に FIFO が
      # 置かれていると、🔴 **開くところで止まる**（`status` / `start` / `restart` が
      # 返らない）。⚠ 通常ファイルには影響しない。⚠ 型の確認は開いたあとに `fstat` で
      # 行う（開く前に `File.file?` を見る形はレースになる）。
      PID_FILE_READ_FLAGS = File::RDONLY | (defined?(File::NONBLOCK) ? File::NONBLOCK : 0)

      # pid ファイルが指す pid。⚠ **pid として読めたときだけ返す** (#627)。
      #
      # 🔴🔴 **`to_i` の結果をそのまま返さないこと。** 空のファイルも壊れたファイルも
      # `0` になり、⚠⚠ **`0` は truthy なうえ `Process.kill(0, 0)` は自分のプロセス
      # グループ宛てなので成功する**。帰結は 2 つとも重い —
      # **`run_start` は `already running (PID 0)` で無言終了**（supervisor が叩き直しても
      # 永久に起動しない）、**`run_stop` は `TERM` を呼び出し元のプロセスグループ全体へ**。
      #
      # ⚠ **nil に倒してよいのは、`write_pid` が「pid として読めない中身」を
      # 見捨てられたものとして置き換えられるから** (#622)。判断と置き換えはロック専用
      # ファイルの `flock` の中で行うので、二重起動にならない (#643)。
      def pid
        return parse_pid(read_pid_file)
      end

      # 直前の `pid`（＝ `read_pid_file`）が**在るのに読めなかった**か (#633)。
      #
      # 🔴🔴 **読み直して確かめない。** 一過性の `EIO` は 2 回目に成功しうるので、
      # ⚠⚠ **確かめ直すと「読めなかった」という事実そのものを捨てる**。
      #
      # ⚠⚠ **`alive_state` を上書きして `super` のあと `pid` を呼び直す利用側は、
      # これも見ること (#635)。** 🔴 `pid` は「無い」も「読めない」も `nil` に畳むので、
      # **`pid&.positive?` のような判定だけだと「読めない」が「動いていない」に化ける**
      # — そこから `run_restart` が停止を飛ばし、二重起動に届く。
      # ⚠ 上流は `abort_if_running!` でも直接これを見るので、**利用側が見落としても
      # 起動は拒む**（→ `Daemon#abort_if_running!`）。
      #
      # 🔴 **判断の入口を通るまで下がらない。** 記録を消すのは `alive_state` /
      # `abort_if_running!` / `run_status` / `run_stop` の入口だけなので、⚠⚠ **`pid` を
      # 直接ポーリングする使い方では、一度失敗すると true のまま**になる（後の読み取りが
      # 成功しても）。⚠ **`alive_state` を通せば下がる。**
      def pid_file_unreadable?
        return !@pid_file_error.nil?
      end

      # pid ファイルの場所に**何かが在る**か (#637)。
      #
      # ⚠⚠ **中身が読めるかは見ない。** 🔴 `pid` は「無い」も「読めない」も
      # 「読めたが pid ではない」も `nil` に畳むので、**第 3 の状態**（FIFO /
      # ディレクトリ / dangling symlink / 空 / ゴミ）を言い分けるのに要る。
      #
      # ⚠ **`lstat` で見る** — 🔴 dangling symlink は `File.exist?` だと false になるが、
      # **そこに置かれていること自体が知りたいこと**だ。
      def pid_file_present?
        File.lstat(pid_file)
        return true
      rescue SystemCallError
        return false
      end

      # ⚠ 読めない pid ファイルでは番号が分からないので、代わりに場所を出す。
      # ⚠ **読み直さない。** 呼ぶ側が持っている pid を渡す（🔴 ここで `pid` を呼ぶと
      # pid ファイルを読み直し、記録してあった errno を消す — #635 Codex P2）。
      # ⚠⚠ **引数の既定を外さないこと (#635 Codex P2・8 巡目)。** これは `v1.23.6` で
      # 公開した形なので、**必須にすると利用側が `ArgumentError` で落ちる**。
      def pid_label(found = pid)
        return "PID #{found}" if found
        return "PID file '#{pid_file}'"
      end

      private

      # pid ファイルを取得する。取れなければ起動しない (#622 / #643)。
      #
      # 🔴 **`abort_if_running!` → `write_pid` の 2 段では閉じない。** pid ファイルが
      # 書かれるのはプロセスの起動から数秒後（`bundle exec` のブート）なので、
      # その窓に入った 2 本目も「未起動」と判断してすり抜ける。両方が起動し、
      # 後から書いた方だけが pid ファイルに残るので、**先の 1 本はどの pid ファイル
      # からも辿れない孤児になる** — #509 / #510 / #532 で潰したのと同じ結末の、
      # start 同士のレース。実例は pooza/mulukhiya-toot-proxy#4675（sidekiq が
      # 2 本立ち、スケジュール登録された全ワーカーが毎サイクル二重投入された）。
      #
      # ⚠⚠ **判断と置き換えを、ロック専用ファイルの `flock` の中で行う** (#643)。
      # ロックを取れるのは 1 本だけで、2 本目は周回の間で少し待つ。1 本目が書き終えた
      # あとに読めば「already running」、待ち切れなければ「Could not acquire」で終わる
      # （どちらも起動しない）。
      # 異常終了で残った pid ファイルは、死んでいると断定できたときに限って置き換える
      # （:unknown では奪わない。触れないだけで生きている可能性がある — #510）。
      # pid として読めない中身（空・壊れている）は、生死を訊かずに置き換える。
      #
      # ⚠ **ここは利用側の override 点でもある**（pid が外から見えるより前に trap を
      # 張る、など）。**`super` を呼ぶ形は保つこと。**
      def write_pid
        if (unusable = unusable_pid_dir)
          abort_unusable_pid_dir!(unusable)
        end
        outcome = nil
        PID_ACQUIRE_ATTEMPTS.times do |attempt|
          sleep(PID_ACQUIRE_WAIT_SECONDS) if attempt.positive?
          outcome = with_pid_lock {try_acquire_pid_file}
          break if outcome == :acquired
        end
        return if outcome == :acquired
        cause = outcome == :busy ? 'the lock stayed busy' : 'the PID file kept changing'
        abort_start!("Could not acquire PID file '#{pid_file}' (#{cause}).",
          'could not acquire pid file', nil)
      end

      # ロックの中で呼ぶ (#643)。取れたら `:acquired`、読み直しが要るなら `:changed`。
      # 起動してはいけないと分かったら、その場で終わる。
      def try_acquire_pid_file
        reset_pid_file_error
        # ⚠ **解釈する前の中身を覚える。** 判断のあとに同じものか確かめるので、
        # `to_i` した結果では足りない（空と `'0'` と `'abc'` が同じ `0` になる）。
        observed = read_pid_file
        abort_unreadable_pid_file!(pid_file_error) if pid_file_unreadable?
        observed_pid = parse_pid(observed)
        # ⚠ **自分が既に取っているなら取得済み。** ここを通さないと、同じプロセスから
        # 2 度呼ばれたときに自分の pid を見て「already running」で終了する。
        return :acquired if observed_pid == Process.pid
        # ⚠ **pid として読めない中身に生死を訊かない。** 訊く相手が居ない —
        # 既定では `Process.kill(0, 0)` が成功して :alive、`alive_state` を上書き
        # している利用側では :dead と、答えが実装で割れる (#627)。
        abort_if_running! if observed_pid
        stat = pid_file_stat
        abort_invalid_pid_file!(stat) if stat && !stat.file?
        return with_old_pid_lock(stat) do
          # ⚠⚠ **判断のあいだに中身が変わっていたら置き換えない。** ロックを取らない
          # 書き手が居る — `remove_pid` と、旧版の start（→ `with_old_pid_lock`）。
          # 置き換えると、その 1 本を孤児にする。⚠ 読み直すのは旧版のロックを取ってから。
          # 🔴 **読み直しが読めなかったときも「変わった」に数える**（リリース前レビュー）。
          # `read_pid_file` は「無い」も「読めない」も nil なので、比べるだけだと
          # 「無いまま」に見えて置き換えていた。次の周回の最初の読みで止まる。
          next :changed unless read_pid_file == observed && !pid_file_unreadable?
          report_hard_linked_pid_file(stat) if stat&.nlink.to_i > 1
          next replace_pid_file(stat)
        end
      end

      # ⚠ symlink / FIFO / ディレクトリは置き換えない。`rename` は名前を差し替える
      # だけなので壊れはしないが、この位置にそれらが置かれる正当な形が無いので、
      # 黙って消さずに起動を止めて知らせる（#629 / #637）。
      def abort_invalid_pid_file!(stat)
        abort_start!("PID file '#{pid_file}' exists but is not a valid PID file (#{stat.ftype}).",
          'pid file invalid', nil)
      end

      # pid ファイルの位置にあるもの。無ければ nil (#643)。
      def pid_file_stat
        return File.lstat(pid_file)
      rescue Errno::ENOENT
        return nil
      rescue SystemCallError => e
        abort_start!("Could not inspect PID file '#{pid_file}'.", 'pid file unusable', e)
      end

      # ⚠ **ハードリンクは置き換えて通す** (#643)。書くのは新しい inode なので、リンク先には
      # 届かない。跡だけ残す — `cp -al` のようなスナップショットでなければ、誰かが仕掛けている。
      def report_hard_linked_pid_file(stat)
        @logger.warn(daemon: app_name, version: package_class.version,
          message: 'pid file is hard linked', nlink: stat.nlink, pid_file:)
      end

      # 自分の pid を書いた一時ファイルで、pid ファイルを置き換える (#643)。置けたら `:acquired`、
      # 置く前に別の書き手が現れたら `:changed`（→ `install_pid_file`）。
      #
      # 🔴🔴 **既存の inode に書かないこと。** 旧版は pid ファイルを開いて中身を
      # 差し替えていたので、開いてから書くまでに経路を別のファイル（ハードリンク）へ
      # すり替えられると、**そのファイルが pid の数字で上書きされた**。`nlink` や
      # `lstat` で確かめても、確かめたあとに張り直される形は閉じられなかった。
      # `rename` は名前を差し替えるだけで、置き換えられた側の中身には触れない。
      # 読む側に見えるのは旧か新のどちらかで、書きかけは見えない。
      # ⚠ mode は `0644` に固定する（umask が `002` だとグループが pid を書き換えられ、
      # `stop` が別のプロセスへ `TERM` を送る）。🔴 **作るときの引数だけでは足りない**
      # (#643 Codex P2) — umask で削られるので、`077` だと `0600` になり、監視から読めない。
      # 自分が作った inode なので `chmod` してよい。
      def replace_pid_file(stat)
        temp = "#{pid_file}.#{SecureRandom.hex(8)}.tmp"
        created = false
        File.open(temp, PID_TEMP_OPEN_FLAGS, 0o644) do |f|
          created = true
          f.chmod(0o644)
          f.write(Process.pid.to_s)
        end
        return install_pid_file(temp, stat)
      rescue SystemCallError => e
        # ⚠ **自分が作った一時ファイルだけを消す。** 名前の形で掃除すると、同じ
        # ディレクトリの他人のファイルを消しうる。
        FileUtils.rm_f(temp) if created
        # 置くところまで届かなければ、pid ファイルは元のまま（自分のものになっていない）。
        abort_start!("Could not write PID file '#{pid_file}'.", 'pid file write failed', e)
      end

      # 起動しなかったことを **stderr と logger の両方**に出して終わる。
      #
      # 🔴🔴 **stderr だけでは `restart` で消える（リリース前レビューの赤）。**
      # `run_restart` は fork した子の stdout / stderr を自分で `File::NULL` へ
      # 付け替えるので、⚠⚠ **「起動しなかった」ことがどこにも残らないまま、親は
      # exit 0 で返る**。supervisor は叩き直し続け、**落ちているのにログが 1 行も
      # 増えない**という形になる。
      def abort_start!(message, reason, error = pid_file_error)
        abort_daemon!("#{message} Not starting #{app_name}.", 'not started', reason, error)
      end

      # 🔴🔴 **止める側の出口にも同じ規則を当てる (#635)。** `run_stop` の `warn` +
      # `exit 1` は `@logger` を通っていなかったので、⚠⚠ **`restart` が
      # 「起動を試みる前に」無音で終わる**経路が残っていた（`run_restart` は
      # `alive_state` が :dead でないときに `run_stop` を通る）。
      def abort_stop!(message, reason, error = pid_file_error)
        abort_daemon!("#{message} Not stopping #{app_name}.", 'not stopped', reason, error)
      end

      # ⚠⚠ **理由（errno）は引数で持ち回る (#635 Codex P2)。** 🔴 ここで
      # `@pid_file_error` を読むと、**メッセージを組み立てる途中の読み直しで消えた
      # あと**の値を見ることになる。呼ぶ側が「決めたときの証拠」を渡す。
      # 🔴🔴 **例外の本文も残す（リリース前レビューの黄・2 観点が独立に指摘）。**
      # ⚠⚠ `warn` は **stderr にしか出ず、`run_restart` の子は stderr を `File::NULL`
      # へ付け替えている**ので、クラス名だけだと「`bundle` が無いのか、常駐の
      # コマンドのパスが変わったのか」を切り分けられない。
      # ⚠ `detail:` は `Logger#create_message` の `mask` を通るので、埋まった URL は
      # 伏せられる（`error:` はクラス名のままにする — 既存の grep が効かなくなる）。
      def abort_daemon!(message, state, reason, error)
        warn message
        @logger.error(daemon: app_name, version: package_class.version,
          message: state, reason:, pid_file:, error: error&.class&.to_s, detail: error&.message)
        exit 1
      end

      # この判断のあいだに読み取りが失敗していたなら、その例外。
      #
      # 🔴🔴 **成功しても消さない (#635 Codex P2・5 巡目)。** ⚠⚠ 上書きされた
      # `alive_state` は `super` のあとにもう一度 `pid` を呼ぶので、**途中の失敗が
      # 後の成功で消える** — 前後で挟むだけでは原理的に見えない。消すのは
      # 「判断を始めるとき」（→ `reset_pid_file_error`）だけにする。
      def pid_file_error
        return @pid_file_error
      end

      # ⚠ **判断の入口で 1 度だけ呼ぶ。** 読み取りごとではない（上記）。
      def reset_pid_file_error
        @pid_file_error = nil
      end

      # pid ファイルの**置き場所**が、symlink を含まない本物のディレクトリか (#632)。
      #
      # 🔴🔴 **`O_NOFOLLOW` も `rename` もパスの最終要素しか見ない。** `tmp/pids` 自体を
      # 別のディレクトリへのリンクにされると、**リンク先のディレクトリにロックと pid ファイルを
      # 作らされ、そこにある同名のファイルを置き換えさせられる**。
      #
      # 🔴🔴 **最終要素だけ見ても足りない (#632 Codex P1)。** ⚠⚠ `tmp` の側を symlink にされると、
      # `tmp/pids` は本物のディレクトリなので検査を通り、**同じ破壊ができる**
      # （旧方式で実測した: victim が pid の数字で上書きされた）。**下から 1 段ずつ見る。**
      #
      # ⚠⚠ **作業ディレクトリより上は見ない。** 🔴 リリース単位のディレクトリを
      # `current` のような symlink で切り替える運用は正当で、そこを拒むと配置ごと壊す。
      # ⚠ そこを書き換えられる相手は、どうせアプリ本体を差し替えられる。
      #
      # 🔴🔴 **逆に、作業ディレクトリ配下（`tmp` / `tmp/pids`）を symlink にする配置は
      # 拒む。** ⚠⚠ Capistrano の `linked_dirs` は既定で `tmp/pids` を共有先への
      # symlink にするので、**その配置では常駐が上がらない**（手で実体へ戻すまで直らない）。
      # ⚠ 手元の利用側と cookbook には該当なしを実測したが、**配布時に残りでも
      # `ls -ld tmp tmp/pids` を取ること**。
      #
      # ⚠ **開いてから確かめられないので TOCTOU は残る。** それでも、入れ替えを
      # 「間に合わせる」必要のある形へ落とせる。
      # ⚠ **使えない段を返す（真偽ではなく）。** 🔴 拒んだときに**どの段が原因か**を
      # 出さないと、運用者は `tmp/pids` を見て「ディレクトリはあるのに」となる
      # （実際に symlink なのは `tmp` の側）。
      def unusable_pid_dir
        return unusable_dir(guarded_dirs)
      end

      # 並べたディレクトリのうち、**`lstat` で本物のディレクトリでない最初の段**を返す。
      # ⚠ pid ファイルと設定のキャッシュ（`ConfigCache`・#651）で共有する。
      def unusable_dir(dirs)
        dirs.each do |dir|
          return dir unless File.lstat(dir).directory?
        rescue SystemCallError
          return dir
        end
        return nil
      end

      # 検査するディレクトリを、pid ファイルの親から**作業ディレクトリの手前まで**並べる。
      #
      # ⚠ **作業ディレクトリに届かない形（`pid_file` を外へ向けている利用側）では、
      # 親 1 段だけ見る** — ⚠ そのまま上へ辿ると `/` まで全段を拒むことになる。
      # ⚠ `working_dir` を持たない混ぜ方（`Daemon` 以外）も同じ扱い。
      # ⚠⚠ **親が作業ディレクトリそのものなら空を返す**（`pid_file` を `tmp/pids` の
      # 外へ向けた利用側）。🔴 **そこは「上は見ない」の側なので検査は 1 段も走らない** —
      # 既定（`tmp/pids`）から動かした利用側では、この守りは効いていない。
      def guarded_dirs(path = pid_file)
        parent = File.expand_path(File.dirname(path))
        base = respond_to?(:working_dir) ? File.expand_path(working_dir.to_s) : nil
        return [parent] unless base
        dirs = []
        dir = parent
        while dir != base
          return [parent] if File.dirname(dir) == dir
          dirs.push(dir)
          dir = File.dirname(dir)
        end
        return dirs
      end

      def abort_unusable_pid_dir!(dir)
        abort_start!("PID directory '#{dir}' is not a usable directory.", 'pid dir unusable', nil)
      end

      # ⚠⚠ **文字列全体が pid として読めるときだけ返す (#627 Codex P1)。**
      #
      # 🔴 **`to_i` では足りない** — `'123abc'.to_i` は `123` を返すので、**先頭が数字
      # なら壊れたファイルでも通る**。⚠⚠ その番号は**無関係なプロセス**でありうるので、
      # `run_stop` がそちらへ `TERM` を送り、`run_start` はそれを常駐だと報告する。
      #
      # 🔴🔴 **`Integer(value, 10)` でも足りない (Codex P1・2 巡目)。** Ruby は
      # **アンダースコアを桁区切りとして受け付ける**ので、`'12_34'` が `1234` になる。
      # ⚠ pid ファイルに書かれてよいのは 10 進の数字だけなので、**変換の前に形を見る**。
      def parse_pid(value)
        value = value.to_s
        # 🔴🔴 **上限を超えていたら、切った先頭を読まない (#629 Codex P1)。**
        # `File.read(path, n)` は EOF に届いたかを教えないので、⚠⚠ **`'123' ＋ 空白 ＋
        # ゴミ` のようなファイルが、切ったうえで `strip` すると `123` として通る** —
        # その番号は無関係なプロセスでありうる。⚠ 上限より 1 バイト多く読んであるので、
        # **超えていること自体は分かる**（奪って復帰する側はそれでよい）。
        return nil if value.bytesize > PID_FILE_MAX_BYTES
        return nil unless (value = value.strip).match?(PID_PATTERN)
        return nil unless (value = value.to_i).between?(1, PID_MAX)
        return value
      end

      # pid ファイルの中身を**解釈せずに**返す。無ければ nil。
      #
      # ⚠⚠ **長さを渡して読むこと。** 2 つ効いている —
      # ①丸ごとメモリへ載せない ②🔴 **長さを渡すと `ASCII-8BIT` で返る**ので、
      # 不正な UTF-8 バイトが混じった pid ファイルでも後段の `strip` / `match?` が
      # `Encoding::CompatibilityError` を上げない（⚠ 引数なしの `File.read` は UTF-8
      # で返るため、そこへ戻すと `pid` から例外が漏れる）。
      # ⚠ `IO#read(len)` は EOF で `nil` を返すので `to_s` が要る。
      def read_pid_file
        File.open(pid_file, PID_FILE_READ_FLAGS) do |f|
          # ⚠⚠ **通常ファイル以外は読まない。** 🔴 FIFO を読むと**返ってこない**
          # （`O_NONBLOCK` で開いているので、開くところまでは止まらない）。
          return nil unless f.stat.file?
          return f.read(PID_FILE_MAX_BYTES + 1).to_s
        end
      rescue Errno::ENOENT
        return nil
      rescue SystemCallError => e
        # ⚠⚠ **「無い」と「読めない」を混ぜない (#633 Codex P2)。** 読めなかった事実を
        # 覚えておき、`alive_state` が :dead ではなく :unknown を返せるようにする
        # （🔴 :dead だと `run_status` が嘘をつき、`run_restart` が停止を飛ばす）。
        @pid_file_error = e
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
        found = pid
        return FileUtils.rm_f(pid_file) if found == expected
        # 🔴🔴 **読めなかったときにだけ残す (#637)。** ⚠ 別の番号が入っているのは
        # **後継が取り直した正常な形**（#532）なので黙る — ⚠⚠ ここで警報を出すと
        # **正常な交代のたびに鳴り、警報が誤報になる**。
        # 🔴 読めない（`nil`）は別 — **stdout / stderr / ログすべて空で exit 0** になり、
        # ⚠⚠ **「stop は成功」に見えて pid ファイルが残る**。その間に pid が再利用されると、
        # `already running (PID N)` が無関係のプロセスを指す。
        # 🔴🔴 **もう無いなら黙る (#637 Codex P2)。** ⚠⚠ 相手の trap が先に
        # **自分の pid ファイルを消す**ので、止める側がここへ来たときには
        # 無くなっていることがある — **これは正常な停止**。
        # 🔴 ここで鳴ると、**警報が誤報になる**（上の「後継が取り直した形」と同じ理由）。
        report_pid_file_left(expected) if !found && pid_file_present?
        return nil
      end

      def report_pid_file_left(expected)
        @logger.warn(daemon: app_name, version: package_class.version,
          message: 'pid file left behind', expected:, pid_file:)
      end
    end
  end
end
