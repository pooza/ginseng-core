# frozen_string_literal: true

module Ginseng
  class Daemon
    # pid ファイルの取得・保持・後始末の一式 (#622 / #627)。⚠ `Daemon` から切り出して
    # ある — **`Daemon` に混ぜて使う前提**で、`pid_file` / `app_name` / `@logger` は
    # 混ぜた側が持つ。
    #
    # 🔴🔴 **この一式の芯は「確認と書き込みを 1 つの原子操作にする」こと。**
    # 分けて書くと、pid ファイルが書かれるまでの数秒（`bundle exec` のブート）に
    # 入った 2 本目も「未起動」と判断してすり抜け、⚠⚠ **後から書いた方だけが pid
    # ファイルに残るので、先の 1 本はどの pid ファイルからも辿れない孤児になる**
    # （実例: pooza/mulukhiya-toot-proxy#4675）。
    #
    # ⚠ **消して作り直さない。** 消す形は「消した直後に別の start が作ったファイル」を
    # 消しうる。奪うのは `flock` の中での**中身の差し替え**で行う。
    module PidFile
      # pid ファイルの取得を試みる回数 (#622)。⚠ **負け方が 4 通りあるので 1 回では
      # 足りない** — ①`O_EXCL` の作成が `EEXIST` ②奪おうとして `flock` が取れない
      # ③ロックの中で読み直したら中身が変わっていた ④作成には勝ったが `flock` の前に
      # 奪われて自分から負けを認めた。いずれも「読み直せば決着がつく」ので少しだけ回す。
      # ⚠⚠ **無制限にはしない** — 回り続けるより起動しないほうが安全（こちらが待って
      # いる間に 2 本目が立つ形を作らない）。
      PID_ACQUIRE_ATTEMPTS = 3

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

      # 奪いに行くときの open の旗 (#629)。
      #
      # ⚠⚠ **`O_NOFOLLOW` が要る。** 🔴 辿ると、pid ファイルを置き換えられる立場の
      # 相手に**デーモンのユーザーが書ける任意のファイルを壊させる**（中身が pid の
      # 数字で上書き＋ truncate される。#622 のリリース前レビューで実測）。
      # ⚠⚠ **定数の無いプラットフォームでは 0 に倒れ、この防御は消える。**
      # 🔴 `File.const_defined?` は継承を見るので使わない — 利用側がトップレベルに
      # `NOFOLLOW` を定義していると true になり、`File::NOFOLLOW` で NameError になる。
      #
      # ⚠ **効くのはパスの最終要素だけ。** ハードリンクも、`tmp/pids` 自体が symlink
      # の場合も辿る（#632）。**読む側（`read_pid_file` / `alive_state`）も辿る**が、
      # そちらは読むだけで、結論は「取れなかった」に落ちる。
      # ⚠ **`create_pid_file` には要らない** — `O_CREAT | O_EXCL` は symlink を
      # `EEXIST` で拒む（dangling なリンクでも作らないことを実測）。
      #
      # 🔴🔴 **symlink が在る限り起動しない（手で消すまで直らない）。** このファイルは
      # 他所で「恒久的な起動不能」を繰り返し潰しているが、ここだけは**意図してそう
      # している** — この位置の symlink が正当でありうる形が無いため。⚠⚠ **理由ごと
      # 消さないこと。**
      PID_FILE_OPEN_FLAGS = File::RDWR | (defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0)

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
        return parse_pid(read_pid_file)
      end

      # ⚠ 読めない pid ファイルでは番号が分からないので、代わりに場所を出す。
      def pid_label
        return "PID #{pid}" if pid
        return "PID file '#{pid_file}'"
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
          observed_pid = parse_pid(observed)
          # ⚠⚠ **自分が既に取っているなら取得済み。** ここを通さないと、同じプロセスから
          # 2 度呼ばれたときに**自分の pid を見て「already running」で終了する**。
          return if observed_pid == Process.pid
          # 🔴 **pid として読めない中身に生死を訊かない。** 訊く相手が居ない —
          # 既定では `Process.kill(0, 0)` が成功して :alive、`alive_state` を上書き
          # している利用側では :dead と、**答えが実装で割れる** (#627)。
          # ⚠ 奪ってよいかは、この下の `reclaim_pid_file` がロックの中で決める。
          abort_if_running! if observed_pid
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
        File.open(pid_file, PID_FILE_OPEN_FLAGS) do |f|
          # ⚠⚠ **通常ファイルであることを開いてから確かめる。** 🔴 `File.file?` を
          # 見てからここへ来るまでに FIFO へ差し替えられると、**`read` が返らない**
          # （このファイルが `LOCK_NB` で避けているハングが、別の入口から入る）。
          return false unless f.stat.file?
          return false unless f.flock(File::LOCK_EX | File::LOCK_NB)
          # ⚠⚠ **ロックを取ってから読み直す。** 自分が読んでからここへ来るまでに
          # 別の start が奪っていれば、**先頭 `PID_FILE_MAX_BYTES + 1` バイト**が
          # 変わっている（奪う側は必ず先頭から書き替えるので、そこだけで足りる）。
          # ⚠ `IO#read(len)` は EOF で `nil` を返すので `to_s` が要る（空のファイルを
          # 奪えなくなる）。
          return false unless f.read(PID_FILE_MAX_BYTES + 1).to_s == observed
          f.rewind
          f.write(Process.pid.to_s)
          f.flush
          f.truncate(f.pos)
          return true
        end
      rescue SystemCallError => e
        # ⚠⚠ **errno を列挙しない (#633)。** 🔴 `O_NOFOLLOW` が symlink に当たったときの
        # errno は**プラットフォームで違う** — Linux / macOS は `ELOOP`、**FreeBSD は
        # `EMLINK`**（NetBSD は `EFTYPE`。⚠ Linux の Ruby では `Errno::EFTYPE` が
        # `Errno::NOERROR` の別名なので、書くと別物を握り潰す）。列挙すると
        # **FreeBSD で例外が突き抜け、`run_restart` の子では backtrace すら消える**。
        # ⚠ 開く直前に消えた (#561)・読めない・書けない・ro・満杯も同じ扱いでよい —
        # **どれも「このファイルは奪えない」**で、次の周回か「取れなかった」に落ちる。
        report_unusable_pid_file(e)
        return false
      end

      # 🔴 **握り潰す前に理由を残す（リリース前レビューの赤）。** stderr は
      # `run_restart` の子で捨てられるので、**syslog に出ないと消える**。
      # ⚠ `ENOENT` は #561 の正常な競合（次の周回で作り直せる）なので黙る —
      # ⚠⚠ **起動が成功する経路で warn を出すと、警報が誤報になる。**
      def report_unusable_pid_file(error)
        return if error.is_a?(Errno::ENOENT)
        @logger.warn(daemon: app_name, version: package_class.version,
          message: 'pid file is not usable', error: error.class.to_s, pid_file:)
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
        # ⚠ 取り合いに負けただけ。**正常な経路なので黙る。**
        return false
      rescue SystemCallError => e
        # 🔴🔴 **ここが `EEXIST` だけだと、`restart` が無音で失敗する（リリース前
        # レビューの赤）。** `tmp/pids` が書けない・ro・満杯・fd 枯渇はどれも
        # 例外のまま抜け、⚠⚠ **`run_restart` の子は stderr を `File::NULL` へ
        # 付け替えているので backtrace すら残らず、親は exit 0 で返る**。
        # ⚠ 奪う側 (`reclaim_pid_file`) と対称にする。
        report_unusable_pid_file(e)
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
        return File.read(pid_file, PID_FILE_MAX_BYTES + 1).to_s if File.file?(pid_file)
        return nil
      rescue SystemCallError
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
    end
  end
end
