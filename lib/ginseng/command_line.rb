# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'timeout'
require 'facets/time'

module Ginseng
  class CommandLine
    include Package

    # サブプロセスへ引き継がせない環境変数。詳細は child_env のコメント (#480)。
    UNSET_ENV_KEYS = ['RBENV_VERSION'].freeze

    attr_reader :args, :stdout, :stderr, :status, :pid, :env, :secrets
    attr_accessor :dir, :user

    def initialize(args = [])
      @logger = logger_class.new
      @env = {}
      @user = nil
      @dir = environment_class.dir
      # ⚠ **既定は空** (#642)。渡さなければ振る舞いは従来と変わらない。
      @secrets = [].freeze
      self.args = args
    end

    # ログに出す前に伏せる値 (#642)。
    #
    # 🔴🔴 **引数そのものが資格情報になることがある** — webhook URL、Uptime Kuma の
    # push URL（**トークンがパスに入る**）など。⚠⚠ `Masking#mask` は**キー名**で判定するので
    # `command:` という 1 つの文字列には効かず、`mask_url` が見るのは userinfo とクエリなので
    # **パスに埋まったトークンは素通り**する。この口が無いと、🔴 **利用側が
    # `log_exec`（private）を写経する**ことになる（THE-POWERNEWS/writersbase-tools#82）。
    #
    # ⚠ **空文字・`nil` は落とす** — 🔴 空文字で `gsub` すると**全文字の隙間に
    # `[FILTERED]` が入る**。
    #
    # ⚠⚠ **長いものから伏せる** — 🔴 短い秘密が長い秘密の一部だと、先に短いほうを
    # 置換して `[FILTERED]def` のような中途半端な形になる。
    # 🔴🔴 **渡された値は複写して凍らせる (#642 Codex P1)。**
    #
    # ⚠⚠ `attr_reader` で配列をそのまま渡すと、**`secrets << value` でここの正規化を
    # 迂回できる** — 🔴 空文字を足されれば全文字の隙間に印が入り、順番が崩れれば
    # `[FILTERED]def` のように**資格情報の一部が残る**。凍らせておけば `FrozenError` で止まる。
    #
    # ⚠ **文字列も複写する** — 🔴 `to_s` は String に対して**自分を返す**ので、
    # 呼び出し側があとから書き換えると**伏せる値がずれて黙って漏れる**。
    def secrets=(values)
      @secrets = values.to_a.compact.map {|value| value.to_s.dup.freeze}
        .reject(&:blank?).uniq.sort_by {|secret| -secret.length}.freeze
    end

    # 文字列の中の資格情報を伏せる (#642)。
    #
    # ⚠ **public にしてある** — 利用側は**例外メッセージ**を伏せるのにも使う
    # （stderr にも資格情報が載りうる）。
    #
    # ⚠⚠ **shellescape した形も伏せる** — `to_s` はエスケープ済みの文字列を返すので、
    # 生の形だけ見ていると**クォートされたときに黙って漏れる**。
    # ⚠ 伏字は `Masking::FILTERED` — 🔴 **利用側で同じ文字列を定義し直さない**ため。
    def masked(text)
      return secrets.inject(text.to_s) do |dest, secret|
        mask_patterns(secret, dest.encoding).inject(dest) do |masked, pattern|
          # ⚠ **ブロック形式で渡す**。置換文字列にすると `\\1` などが
          # 後方参照として食われる。
          masked.gsub(pattern) {Masking::FILTERED}
        end
      end
    end

    def args=(args)
      @args = args.to_a
      @stdout = nil
      @stderr = nil
      @status = nil
    end

    def env=(env)
      @env = env.to_h
      @stdout = nil
      @stderr = nil
      @status = nil
    end

    def to_s
      return args.map do |arg|
        arg.is_a?(Symbol) ? arg : arg.to_s.shellescape
      end.join(' ')
    end

    # 締切で TERM を送ってから、KILL に切り替えるまでの猶予（秒）。
    KILL_GRACE_SECONDS = 2

    # KILL を送ってから、出力のパイプが閉じるのを待つ上限（秒）。⚠ 止められない相手
    # （下記）を見切るまでの時間でもある。
    REAP_GRACE_SECONDS = 1

    # 🔴🔴 **締切が来たら、子プロセスを止めてから `Timeout::Error` を上げる。**
    #
    # ⚠⚠ 以前は `Timeout.timeout { Open3.capture3(...) }` の形で、締切が来ても `capture3` の
    # 後始末が**子プロセスの終了を待つ**ので、例外が上がるのは子が終わった後だった
    # （`sleep 5` に 1 秒の締切で 5.0 秒後。Linux と FreeBSD 15.1 で実測）。
    # 🔴 **締切は一度も効いておらず**、超えた子は孤児のまま完走し、締切の後に間に合った子は
    # **成功しているのに `Timeout::Error`** になっていた（pooza/mulukhiya-toot-proxy#4794）。
    #
    # 🔴 **止められない子がいる。**
    # - 別のユーザーへ降りた子（`user=` の `sudo` 経由、権限を落とす補助コマンド）。こちらから
    #   シグナルを送れない（`EPERM`）
    # - プロセスグループを抜けた子孫（`setsid` など）。グループ宛てのシグナルが届かない
    # ⚠⚠ **そのときも締切で戻る**（`Timeout::Error`。メッセージに `still running` と入り、
    # error を 1 行残す）— 🔴 **子は動き続ける**。止めたい利用側は、止める手段を自分で持つこと。
    # ⚠ 戻るまでの上限は、締切 ＋ `KILL_GRACE_SECONDS` ＋ `REAP_GRACE_SECONDS`。
    # 🔴 **残っていると分かるのは、出力のパイプを握っている相手だけ**（→ `drained?`）。
    # 出力を閉じてから居座る相手は、止められていなくても分からない。
    # ⚠ Windows はプロセスグループへのシグナルが使えないので、従来の形のまま。
    # ⚠ **0 以下は「締切なし」**（`Timeout.timeout(0)` と同じ意味を保つ）。
    def exec(timeout: nil)
      secs = Time.elapse do
        Bundler.with_unbundled_env do
          if deadline?(timeout) && !environment_class.win?
            capture_until(timeout)
          else
            block = proc {@stdout, @stderr, @status = Open3.capture3(*spawn_args, chdir: dir)}
            timeout ? Timeout.timeout(timeout, &block) : block.call
          end
        end
      end
      @pid = @status.pid
      @status = @status.to_i
      log_exec(secs, success: @status.zero?)
      return @status
    end

    def bundle_install
      Bundler.with_unbundled_env do
        return system(child_env, 'bundle', 'install', chdir: dir)
      end
    end

    def exec_system
      start = Time.now
      Bundler.with_unbundled_env do
        if @user
          result = system(sudo_command, chdir: dir)
        else
          result = system(child_env, to_s, chdir: dir)
        end
        log_exec(Time.now - start, success: result)
      end
    end

    private

    # 伏せる形を、**本文側の符号化に寄せてから**返す (#642 Codex P2)。
    #
    # 🔴🔴 **符号化が食い違うと `gsub` が落ちる。** 実測: UTF-8 の非 ASCII な秘密を
    # Shift_JIS / BINARY の本文へ当てると `Encoding::CompatibilityError`。
    # ⚠⚠ **コマンドは成功しているのに `log_exec` が例外を上げる** —
    # `exec` / `exec_system` が失敗に化ける。
    #
    # ⚠ **その符号化で表せない秘密は、本文に現れようが無い** — 当てずに飛ばしてよい
    # （🔴 伏せ損ねにはならない）。
    def mask_patterns(secret, encoding)
      return [secret, secret.shellescape].uniq.filter_map do |pattern|
        convert_encoding(pattern, encoding)
      end
    end

    # ⚠ **BINARY だけ `force_encoding`** — 🔴 `encode` は非 ASCII を必ず
    # `UndefinedConversionError` にするが、BINARY の本文に入っているのは
    # **元のバイト列そのもの**なので、ラベルを合わせるのが正しい。
    def convert_encoding(pattern, encoding)
      return pattern if pattern.encoding == encoding
      return pattern.dup.force_encoding(encoding) if encoding == Encoding::BINARY
      return pattern.encode(encoding)
    rescue EncodingError
      return nil
    end

    # サブプロセスへ渡す環境変数。Bundler.with_unbundled_env が剥がすのは
    # BUNDLE_* / GEM_* / RUBYLIB / RUBYOPT 等「Bundler が設定したもの」だけで、
    # rbenv は管轄外なので RBENV_VERSION は残る。Ruby のパッチアップを跨ぐ
    # デプロイの瞬間、旧 Ruby で稼働中の親（sidekiq 等）から RBENV_VERSION を
    # 引き継いだ子が旧 Ruby で起動し、新 SHA の git gem が materialize されて
    # いない側の gems を見て Bundler::PathError で落ちる (#480)。明示的に unset
    # し、子は .ruby-version / rbenv の通常解決に任せる。
    # 呼び出し側が env で明示指定した場合はそちらを優先する。
    def child_env
      return UNSET_ENV_KEYS.to_h {|key| [key, nil]}.merge(@env.stringify_keys)
    end

    def log_exec(secs, success:)
      params = {
        command: masked(to_s), dir:, env: masked_env, user: @user,
        status: @status, seconds: secs.round(3)
      }
      success ? @logger.info(params) : @logger.error(params)
    end

    # 🔴 **`env:` の値も伏せる (#642)。**
    #
    # ⚠⚠ **同じ資格情報を環境変数で渡す形では、伏せたつもりで漏れる**。
    # 実測: キー名が `TOKEN` なら上流の `mask` が落とすが、🔴 `PUSH_URL` のような
    # 名前だと**パスに埋まったトークンがそのまま出る**。
    #
    # 🔴🔴 **String 以外は触らない（リリース前レビューの黄）。** ⚠⚠ `masked` は
    # `text.to_s` から始まるので、そのまま通すと **`nil` が `""` に、数値が文字列に
    # 変わる** — 🔴 `child_env` は **`nil` を「その環境変数を外す」の意味で使う**
    # （`UNSET_ENV_KEYS`）ので、`secrets` を渡した日だけログの意味が変わる。
    # ⚠ 「`secrets` が空なら触らない」だけでは、**この機能を使った瞬間に型が変わる**。
    def masked_env
      return @env if secrets.empty?
      return @env.transform_values {|value| value.is_a?(String) ? masked(value) : value}
    end

    def deadline?(timeout)
      return timeout.is_a?(Numeric) && timeout.positive?
    end

    def spawn_args
      return @user ? [sudo_command] : [child_env, to_s]
    end

    # ⚠⚠ **プロセスグループごと起こす。** `to_s` はシェルを経由しうるので、子の番号だけに
    # シグナルを送ると**シェルだけが死んで本体が残る**。
    # ⚠ 出力は別スレッドで読む — 待っているあいだにパイプのバッファが埋まると子が止まる。
    #
    # 🔴🔴 **`popen3` をブロック形式で使わない (#684 Codex P1)。** ブロック形式は出口で
    # **子の終了を待つ**ので、止められなかった子（上記）がいると、`Timeout::Error` を
    # 上げたあとでそこに掛かり、**子が終わるまで戻らない**（＝直す前と同じ）。
    # ⚠ 回収は `waiter`（`Process.detach` のスレッド）に任せる — 待たなくてもゾンビは残らない。
    def capture_until(timeout)
      deadline = monotonic + timeout
      stdin, stdout, stderr, waiter = Open3.popen3(*spawn_args, chdir: dir, pgroup: true)
      stdin.close
      readers = [stdout, stderr].map {|io| Thread.new {io.read}}
      unless await(waiter, readers, deadline)
        terminate(waiter.pid)
        settled = true
        expire!(waiter.pid, timeout, stopped: drained?(readers))
      end
      settled = true
      @stdout, @stderr = readers.map(&:value)
      @status = waiter.value
    ensure
      # 🔴 **外から `Thread#kill` で中断されても、子を残さない。**締切の猶予（TERM → KILL）の
      # 途中で外側の締切に切られると、後始末ごと飛ばされる。ここは待たずに KILL する。
      abandon(waiter.pid) if waiter && !settled
      close_pipes(readers, [stdout, stderr])
    end

    # 子の終了と、出力の読み切りを締切まで待つ。間に合えば true。
    #
    # ⚠⚠ **出力を読み切るところまで締切に含める。**先頭が終わっても、パイプを握った子孫
    # （`sh -c 'sleep 30 &'`）が残っていると `read` は戻らない。
    def await(waiter, readers, deadline)
      return false unless waiter.join(remaining(deadline))
      return readers.all? {|reader| reader.join(remaining(deadline))}
    end

    def remaining(deadline)
      return [deadline - monotonic, 0].max
    end

    # ⚠⚠ **止められなかったことを、止めたことにしない (#684 Codex P1)。** 例外のクラスは
    # 同じ（呼び出し側の `rescue Timeout::Error` を壊さない）だが、文言と error の行で分かる。
    def expire!(pgid, timeout, stopped:)
      message = "execution expired (#{timeout}s): #{masked(to_s)}"
      raise Timeout::Error, message if stopped
      @logger.error(command: masked(to_s), pgid:, timeout:,
        message: 'timed out, but the child could not be stopped')
      raise Timeout::Error, "#{message} (still running: output still held, pgid #{pgid})"
    end

    def abandon(pgid)
      signal_group('KILL', pgid) if group_alive?(pgid)
    end

    # ⚠ 読み手を止めてから閉じる。🔴 こちらの端を閉じ忘れると、止められなかった子が
    # 終わるまで読み手のスレッドとパイプが残る。⚠ 子の側は、次に書いたとき `EPIPE` を受ける。
    def close_pipes(readers, pipes)
      readers&.each {|reader| reader.kill if reader.alive?}
      pipes.compact.each {|io| io.close unless io.closed?}
    end

    # 締切を過ぎた子をプロセスグループごと止める。⚠ 止まったかは、ここでは答えない
    # （→ `drained?`）。
    #
    # ⚠⚠ **先頭のプロセスが終わったことを「止まった」と読まない。**`to_s` がシェルを経由すると
    # 先頭はシェルで、TERM で先に死ぬ。TERM を無視する本体がグループに残るので、
    # **グループが空になったか**で見て、残っていれば KILL する。
    # ⚠ ここの「残っている」にはゾンビも入る（下記）。その場合は猶予いっぱい待ってから
    # KILL を送ることになるが、害は無い。
    def terminate(pgid)
      signal_group('TERM', pgid)
      deadline = monotonic + KILL_GRACE_SECONDS
      sleep(0.05) while group_alive?(pgid) && monotonic < deadline
      signal_group('KILL', pgid) if group_alive?(pgid)
    end

    # 出力のパイプが両方とも閉じたか（＝書き手が 1 つも残っていないか）。
    #
    # 🔴🔴 **「止まったか」は、グループではなくパイプで決める (#684)。**
    # - ⚠⚠ **グループはゾンビも数える。** 親に回収されない子（コンテナで PID 1 が回収しない
    #   構成など）は、止めたあともグループに残り、`kill(0, -pgid)` が通る。🔴 グループで
    #   決めると、**止めたものを「まだ動いている」と報告する**（CI のコンテナで実際に出た）
    # - ⚠⚠ **グループを抜けた子孫は、グループからは見えない** (Codex P2)。`setsid` した
    #   子孫は、グループが空になったあとも動き続ける
    # ⚠ 生きている書き手が 1 つでもパイプを握っていれば、読み手は戻らない。ゾンビは握らない。
    # 🔴 **限界**: 出力を閉じて（付け替えて）居座る相手は、ここからは見えない。
    def drained?(readers)
      deadline = monotonic + REAP_GRACE_SECONDS
      return readers.all? {|reader| reader.join(remaining(deadline))}
    end

    def monotonic
      return Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # ⚠ 送る直前に終わっていることがある（`ESRCH`）。そのときは何もしない。
    # ⚠ 送れない（`EPERM`）も、ここでは何もしない — 止まったかは `drained?` が
    # パイプを見て決め、止められなければ `expire!` が 1 行だけ残す。
    def signal_group(signal, pgid)
      Process.kill(signal, -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # ⚠ 触れない（`EPERM`）は「居る」。居ないと言い切れるのは `ESRCH` だけ。
    def group_alive?(pgid)
      Process.kill(0, -pgid)
      return true
    rescue Errno::ESRCH
      return false
    rescue Errno::EPERM
      return true
    end

    def sudo_command
      parts = ['sudo', '-u', @user, 'env']
      UNSET_ENV_KEYS.each {|key| parts.push('-u', key)}
      @env.stringify_keys.each {|k, v| parts.push("#{k}=#{v}")}
      return [*parts.map(&:shellescape), 'sh', '-c', to_s.shellescape].join(' ')
    end
  end
end
