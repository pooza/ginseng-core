# frozen_string_literal: true

require 'open3'

module Ginseng
  class Daemon
    # pid ファイルの番号が「うちの常駐か」を、コマンド行で確かめる (#676)。
    #
    # 🔴 **pid の生死だけでは、番号の再利用を見抜けない。** 残った pid ファイルの番号を
    # 別のプロセスが引くと、`start` は「already running」で起動しない（実例: OS の再起動後に
    # puma が約 6 分上がらなかった。pooza/mulukhiya-toot-proxy#4792）。
    # ⚠⚠ **pid ファイルは正常停止でも残りうる** — 既定の `start` は `exec` するので、
    # `run_start` が張った TERM / INT の trap は置き換わった時点で消える。TERM を直接送る
    # 停止（systemd の `ExecStop=/bin/kill -TERM $MAINPID` など）では毎回残る。
    # ＝ **残さないことは保証できないので、残っても取り違えない側で閉じる。**
    #
    # ⚠⚠ **既定では何もしない。利用側が `process_pattern` を宣言したときだけ効く。**
    # 「うちの常駐」の姿は利用側ごとに違い（`exec` する先・プロセス名の書き換え）、
    # gem からは決められない。
    #
    #   def process_pattern
    #     return Regexp.union(
    #       launcher_pattern('puma_daemon.rb'),                   # 起動スクリプトのまま
    #       exec_pattern('puma', '--config', puma_config_path),   # exec した直後
    #       /\Apuma [\d.]+ \(.*\) \[#{Regexp.escape(app_tag)}\]/, # puma が書き換えたあと
    #     )
    #   end
    #
    # ⚠ `puma_config_path` / `app_tag` は利用側のメソッド（gem には無い）。3 つ目の形は
    # 常駐ごとに違うので、**動いている常駐の `ps -ww -o command= -p <pid>` を見て書く**。
    #
    # ⚠⚠ **見抜けるのは、こちらから触れる番号だけ**（同じユーザーのプロセス。root なら
    # 全部）。触れない番号（`EPERM`。別ユーザーのプロセスが引いた場合）は従来どおり
    # :unknown で、`start` は起動しない — 🔴 そこを :dead へ倒すと、生きている常駐の上に
    # 2 本目を立てうる (#510)。
    #
    # ⚠ **時刻では見ない。** 「プロセスの開始時刻が pid ファイルの書き込みより後なら他人」と
    # する案は、時計が飛ぶと本物を他人と誤る向きに倒れる（#676）。
    module ProcessIdentity
      # うちの常駐のコマンド行に一致する `Regexp`。⚠ **利用側の宣言点。** nil なら見ない。
      #
      # 🔴🔴 **常駐が取りうる姿を全部挙げること。** 挙げ漏らした姿は「他人」になり、
      # **`start` が 2 本目を立て、`stop` は TERM を送らずに pid ファイルを消す**。
      # ⚠⚠ 姿は 1 つではない — 起動スクリプトのまま居る間（`exec` の前、`exec` しない
      # 常駐はずっと）、`exec` した直後、常駐がプロセス名を書き換えたあと
      # （puma / sidekiq は書き換える）。⚠ `launcher_pattern` / `exec_pattern` が使える。
      # ⚠ **部分一致を広く取らないこと** — 他人を「うちの常駐」と答えると、従来どおり
      # 「already running」で起動せず、`stop` はそこへ TERM を送る。
      # 🔴 **`Regexp` を返すこと。** 文字列を返すと「分からない」扱いになり、身元は
      # 見られない（error を 1 行残す）。⚠ 例外を上げた場合も同じ。
      def process_pattern
        return nil
      end

      # 起動スクリプトのまま居るプロセスの姿（`bin/xxx_daemon.rb start`）。
      #
      # ⚠⚠ **スクリプト名だけの部分一致にしない。** `vim bin/xxx_daemon.rb` や
      # `bin/xxx_daemon.rb stop` まで「うちの常駐」と答えると、`stop` がそこへ送る。
      # ⚠ `restart` も常駐の姿 — `run_restart` は fork した子がそのまま `run_start` へ進む。
      def launcher_pattern(script)
        return %r{(?:\A|[\s/])#{Regexp.escape(script)} (?:start|restart)(?:\s|\z)}
      end

      # `exec` した直後の姿（`ruby .../bin/puma --config <path>`）。
      # ⚠ **引数は末尾まで一致させる**（`<path>.bak` を拾わない）。フルパスを渡せば、
      # 同じホストの別のチェックアウトと見分けられる。
      def exec_pattern(*args)
        return %r{(?:\A|[\s/])#{args.map {|v| Regexp.escape(v.to_s)}.join(' ')}(?:\s|\z)}
      end

      private

      # その番号は、うちの常駐ではないと言い切れるか。
      #
      # ⚠⚠ **分からないときは false（＝うちの常駐として扱う）へ倒す。** 🔴 true と誤ると
      # `start` が pid ファイルを奪って 2 本目を立てる。「起動しない」は外から見えるが、
      # **二重起動は黙って進む**ので、迷ったら従来どおりの側に置く。
      # ⚠ 分からない場合 = コマンド行が取れない（`ps` が無い・失敗した・空を返した）／
      # 宣言が読めない（`process_pattern` が例外を上げた・`Regexp` でないものを返した）。
      #
      # 🔴🔴 **`Regexp` でない宣言を `match?` へ流さない。** `String#match?` は**引数の側を
      # 正規表現にする**ので、パターンとコマンド行の役が入れ替わり、本物の常駐がほぼ必ず
      # 不一致になる（＝黙って 2 本目が立つ）。⚠ `'puma_daemon.rb start'` と書く誤りは自然。
      # ⚠⚠ **`process_pattern` も rescue の内側で呼ぶ。** 外に置くと、宣言の中の例外が
      # `status` / `restart` をログ無しで抜ける。
      #
      # ⚠ **他人と答えるときは warn を 1 行残す。** 🔴 `start` はこのあと黙って pid ファイルを
      # 奪うので、ここで残さないと**挙げ漏らしによる二重起動の瞬間が、どこにも記録されない**。
      # ⚠⚠ **コマンド行そのものは載せない** — 他人のプロセスの引数で、資格情報を含みうる。
      # 番号があれば、運用者が `ps` で見られる。
      def identity_mismatch?(found)
        return false unless pattern = process_pattern
        unless pattern.is_a?(Regexp)
          raise TypeError, "process_pattern must be a Regexp (#{pattern.class})"
        end
        line = process_command_line(found)
        return false if line.empty?
        return false if pattern.match?(line)
        @logger.warn(daemon: app_name, version: package_class.version,
          message: 'process identity mismatch', pid: found)
        return true
      rescue StandardError => e
        @logger.error(daemon: app_name, version: package_class.version,
          message: 'process identity unavailable', error: e, pid: found)
        return false
      end

      # ⚠ **`/proc` ではなく `ps` を使う。** FreeBSD では `/proc` が既定でマウントされて
      # いない。⚠ `-ww` は幅で切られないようにするため — 🔴 **切られるとパターンの後半が
      # 落ち、うちの常駐を他人と誤る**。
      def process_command_line(found)
        out, status = Open3.capture2('ps', '-ww', '-o', 'command=', '-p', found.to_s,
          err: File::NULL)
        return '' unless status.success?
        return out.strip
      end
    end
  end
end
