# frozen_string_literal: true

require 'securerandom'

module Ginseng
  class Daemon
    # 常駐の設定を `tmp/cache/<name>.yaml` へ書き出す一式 (#651)。⚠ `Daemon` から
    # 切り出してある — **`Daemon` に混ぜて使う前提**で、`name` / `@config` と、
    # ディレクトリの検査（`PidFile` の `guarded_dirs` / `unusable_dir`）は混ぜた側が持つ。
    #
    # ⚠ 利用側は書いたものを読み戻す（`mulukhiya-toot-proxy` の `setup_sidekiq` /
    # `app/initializer/sidekiq.rb` が `config_cache_path` を `YAML.load_file`）ので、
    # **パスと中身の形は変えない。**
    module ConfigCache
      # ⚠⚠ pid ファイル（`PID_TEMP_OPEN_FLAGS`）と同じ形。書くのは、いま自分が作った
      # inode だけになる。
      CONFIG_CACHE_OPEN_FLAGS = File::WRONLY | File::CREAT | File::EXCL | PidLock::NOFOLLOW_FLAG

      # ⚠ 中身は `application.<name>` と `local.<name>` の合成で、**資格情報が入りうる**
      # （例: sidekiq の認証）。
      CONFIG_CACHE_MODE = 0o600

      def save_config
        config = @config.raw['application'][name]
        if values = @config.raw['local']&.dig(name)
          config.deep_merge!(values)
        end
        write_config_cache(config.to_yaml)
      end

      def config_cache_path
        return File.join(environment_class.dir, "tmp/cache/#{name}.yaml")
      end

      private

      # 🔴🔴 **既存のファイルに書かない (#651)。** 旧版は `File.write` で、
      # ①`<name>.yaml` が symlink なら**リンク先を YAML で上書き（truncate）した**
      # ②mode を渡していないので `0666 & ~umask`（umask `022` なら **誰でも読める `0644`**）
      # だった。⚠ #643 の `replace_pid_file` と同じく、`O_EXCL` で作った一時ファイルに
      # 書いて `rename` で置く。`rename` は名前を差し替えるだけで、置き換えられた側
      # （symlink なら symlink そのもの）の先には触れない。
      #
      # ⚠ **`tmp/cache` と `tmp` は `lstat` で見る**（`O_NOFOLLOW` も `rename` も最終要素しか
      # 見ない — #632 と同じ理由）。🔴 `tmp/cache` を他所へのリンクにされると、書いた設定を
      # そのまま読まれる。
      # ⚠ mode は umask に関係なく `0600`。作るときの引数は umask で**削られる**ので
      # `chmod` もする。umask は削るだけなので広がる心配は無いが、🔴 **狭くなると読み戻す
      # 本人が読めない**（umask `0477` だと `0200` になり、`YAML.load_file` が落ちる —
      # #659 Codex P2）。⚠ pid ファイル（#643 Codex P2）と同じ理由。
      # ⚠ **失敗は例外で返す**（`abort` しない）。`save_config` は常駐の起動の外
      # （利用側の puma など）からも呼ばれる。`run_start` の中では `start` の rescue が拾う。
      def write_config_cache(body)
        path = config_cache_path
        if dir = unusable_dir(guarded_dirs(path))
          raise ConfigError, "Config cache directory '#{dir}' is not a usable directory."
        end
        temp = "#{path}.#{SecureRandom.hex(8)}.tmp"
        created = false
        File.open(temp, CONFIG_CACHE_OPEN_FLAGS, CONFIG_CACHE_MODE) do |f|
          created = true
          f.chmod(CONFIG_CACHE_MODE)
          f.write(body)
        end
        File.rename(temp, path)
      rescue SystemCallError
        # ⚠ **自分が作った一時ファイルだけを消す**（`replace_pid_file` と同じ）。
        FileUtils.rm_f(temp) if created
        raise
      end
    end
  end
end
