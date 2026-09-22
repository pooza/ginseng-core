# frozen_string_literal: true

module Ginseng
  class Daemon
    # pid ファイルの取得に使う排他の一式 (#643)。⚠ `PidFile` から切り出してある —
    # **`PidFile` に混ぜて使う前提**で、`pid_file` / `abort_start!` は混ぜた側が持つ。
    #
    # 2 つのロックを扱う。①ロック専用ファイル（`pid_lock_file`）の `flock` —
    # start 同士の排他の本体 ②既存の pid ファイルの inode への `flock` — 移行期の
    # 旧版（1.24.0 まで）の start と排他を合わせるためだけのもの。
    # ⚠ **どちらのファイルにも書かない**（`flock` を取るだけ）。
    module PidLock
      # 最終要素の symlink を辿らない旗。⚠⚠ **定数の無いプラットフォームでは 0 に倒れ、
      # この防御は消える。**
      # 🔴 `File.const_defined?` は継承を見るので使わない — 利用側がトップレベルに
      # `NOFOLLOW` を定義していると true になり、`File::NOFOLLOW` で NameError になる。
      # ⚠ **効くのはパスの最終要素だけ。** `tmp/pids` 自体の symlink は
      # `unusable_pid_dir` が塞いでいる（#632）。
      NOFOLLOW_FLAG = defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0

      # ロック専用ファイル（`pid_lock_file`）を開くときの旗 (#643)。
      #
      # ⚠⚠ このファイルには書かない（`flock` を取るだけ）ので、ハードリンクで別のファイルを
      # 指されても中身は壊れない。`O_NOFOLLOW` は外さない — 辿ると、`O_CREAT` がリンク先に
      # ファイルを作る。`O_NONBLOCK` も要る — FIFO を置かれると開くところで止まる
      # （型は開いてから `fstat` で確かめる）。symlink / FIFO / ディレクトリが在る限り起動しない
      # （この位置にそれらが置かれる正当な形が無いため。手で消すまで直らない）。
      # ⚠ **書かないのに `RDWR` で開く** — Linux の NFS は `flock` を POSIX ロックで代用するので、
      # 書き込み用に開いていない fd の排他ロックは `EBADF` になる。
      # 🔴 **`O_NONBLOCK` はテストで固定できていない。** Linux は FIFO を `O_RDWR` で開くと
      # 止まらずに返す（POSIX では未定義の拡張）ので、Linux の CI では外しても緑のまま。
      # FreeBSD では保証が無いので外さないこと。
      PID_LOCK_OPEN_FLAGS = File::RDWR | File::CREAT | NOFOLLOW_FLAG |
        (defined?(File::NONBLOCK) ? File::NONBLOCK : 0)

      # 旧版（1.24.0 まで）と排他を合わせるために、既存の pid ファイルへ `flock` を取るときの旗
      # (#643 Codex P1 → `with_old_pid_lock`)。⚠ **書かない**（`O_TRUNC` も無い）。
      # `RDWR` にするのは NFS のため（`PID_LOCK_OPEN_FLAGS` と同じ理由）。
      # ⚠ この名前は 1.24.0 まで「奪うときに中身を書き換える open の旗」だった。
      PID_FILE_OPEN_FLAGS = File::RDWR | NOFOLLOW_FLAG |
        (defined?(File::NONBLOCK) ? File::NONBLOCK : 0)

      # 取得の排他に使うファイル (#643)。
      #
      # ⚠⚠ **消さないこと。** 消すと、消す前の inode をロックした 1 本と、作り直された
      # inode をロックした 1 本が**両方「取れた」と読む** — pid ファイルそのものを
      # ロックしていた旧版の取り違えが、こちらへ移るだけになる。
      # ⚠ ロックはプロセスが死ねば外れるので、ファイルが残っても起動は阻まない。
      def pid_lock_file
        return "#{pid_file}.lock"
      end

      private

      # 🔴🔴 **置き換えのあいだ、旧版（1.24.0 まで）の start と排他を合わせる (#643 Codex P1)。**
      #
      # 旧版は pid ファイルそのものの inode に `flock` を取り、その中で中身を書く。
      # ⚠⚠ ロック専用ファイルしか見ないと、旧版が `O_EXCL` で作ってから書くまでの空の
      # pid ファイルを「変わっていない」と読んで置き換え、旧版は**消えた inode に書いて
      # 「取れた」と読む** — 2 本とも起動し、辿れるのは新版だけになる。
      # 旧版は `LOCK_NB` で取れなければ引き下がるので、置き換えるあいだ同じ inode を
      # 握っていれば、旧版は次の周回で新版の pid を読んで止まる。
      # ⚠ **このファイルには書かない**（`flock` を取るだけ）。開いたものがいまの経路と
      # 同じ inode かも確かめる。
      # ⚠ 旧版が `O_EXCL` の open から `flock` までの数 µs の間に、新版が判断から
      # 置き換えまでを終えた場合だけは排他が効かない。
      def with_old_pid_lock(stat)
        return yield unless stat
        File.open(pid_file, PID_FILE_OPEN_FLAGS) do |file|
          current = file.stat
          return :changed unless current.dev == stat.dev && current.ino == stat.ino
          return :changed unless lock_pid_file(file)
          return yield
        end
      rescue Errno::ENOENT
        return :changed
      rescue SystemCallError => e
        abort_start!("Could not lock PID file '#{pid_file}'.", 'pid file lock failed', e)
      end

      # ロック専用ファイルの `flock` の中でブロックを走らせ、その結果を返す (#643)。
      # ロックが取れなければ `:busy`。
      #
      # ⚠ 放すのは fd を閉じたとき。`abort_start!` の `exit` でも `ensure` で閉じる。
      def with_pid_lock
        lock = open_pid_lock_file
        begin
          return :busy unless acquire_pid_lock(lock)
          return yield
        ensure
          lock.close
        end
      end

      # ⚠⚠ **ロックを取れたあとで、そのパスがまだ同じ inode を指しているか確かめる**
      # （リリース前レビュー）。判断の最中にロック専用ファイルを消されると、次の start は
      # 新しい inode を作ってロックを取れてしまい、2 本とも起動しうる。
      # 🔴 **ロック操作の失敗を例外のまま抜けさせない。** 抜けると `run_start` の rescue が
      # `Could not start` と言うだけで、理由がロックだと読めない。
      def acquire_pid_lock(lock)
        stat = lock.stat
        abort_invalid_pid_lock_file!(stat) unless stat.file?
        return false unless lock_pid_file(lock)
        return same_pid_lock_file?(stat)
      rescue SystemCallError => e
        abort_start!("Could not lock PID lock file '#{pid_lock_file}'.", 'pid lock failed', e)
      end

      def same_pid_lock_file?(stat)
        current = File.lstat(pid_lock_file)
        return current.dev == stat.dev && current.ino == stat.ino
      rescue SystemCallError
        return false
      end

      # ⚠ **`0600` で作る**（リリース前レビュー）。`flock` は開けさえすれば誰でも取れるので、
      # 読めるだけの相手でもロックを握り続けて起動を止められる。
      # ⚠ **開けないことを例外のまま抜けさせない。** `run_restart` の子は stderr を
      # `File::NULL` へ付け替えているので、backtrace すら残らない（#633）。
      # errno は列挙しない — `O_NOFOLLOW` が symlink に当たったときの errno は
      # プラットフォームで違う（Linux / macOS は `ELOOP`、FreeBSD は `EMLINK`）。
      def open_pid_lock_file
        return File.open(pid_lock_file, PID_LOCK_OPEN_FLAGS, 0o600)
      rescue SystemCallError => e
        abort_start!("Could not open PID lock file '#{pid_lock_file}'.", 'pid lock file unusable',
          e)
      end

      def abort_invalid_pid_lock_file!(stat)
        abort_start!("PID lock file '#{pid_lock_file}' is not a regular file (#{stat.ftype}).",
          'pid lock file invalid', nil)
      end

      # `flock` を取る（ロック専用ファイルと、旧版との排他の両方）。⚠ **テストのための継ぎ目**でもある（別の start が
      # 判断している最中、という瞬間は実プロセスを並べても順序を握れないので作れない）。
      #
      # ⚠⚠ **`LOCK_NB` で待たない。** 🔴 待つ形にすると、`tmp/pids` に書ける外部プロセスが
      # ロックを握り続けたときに**無限に待つ**。取れなければ次の周回へ回して、最後は
      # 「取れなかった」で終わる — **ハングより起動しないほうがよい**。
      def lock_pid_file(file)
        return file.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end
  end
end
