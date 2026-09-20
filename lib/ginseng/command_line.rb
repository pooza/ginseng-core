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

    def exec(timeout: nil)
      secs = Time.elapse do
        Bundler.with_unbundled_env do
          block = proc do
            if @user
              @stdout, @stderr, @status = Open3.capture3(sudo_command, chdir: dir)
            else
              @stdout, @stderr, @status = Open3.capture3(child_env, to_s, chdir: dir)
            end
          end
          timeout ? Timeout.timeout(timeout, &block) : block.call
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

    def sudo_command
      parts = ['sudo', '-u', @user, 'env']
      UNSET_ENV_KEYS.each {|key| parts.push('-u', key)}
      @env.stringify_keys.each {|k, v| parts.push("#{k}=#{v}")}
      return [*parts.map(&:shellescape), 'sh', '-c', to_s.shellescape].join(' ')
    end
  end
end
