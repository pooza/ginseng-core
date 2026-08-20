# frozen_string_literal: true

require 'socket'

module Ginseng
  class Environment
    def self.name
      return File.basename(dir)
    end

    def self.hostname
      return Socket.gethostname
    end

    def self.dir
      return File.expand_path('../..', __dir__)
    end

    def self.ip_address
      udp = UDPSocket.new
      udp.connect('128.0.0.0', 7)
      return Socket.unpack_sockaddr_in(udp.getsockname)[1]
    ensure
      udp.close
    end

    # 実行環境。ENV['RACK_ENV'] / ENV['RAILS_ENV'] を config より優先して見る。
    # config だけを見ていたため、rc.d が RACK_ENV=production を渡していても
    # /environment 未設定のアプリは常に :development に倒れ、本番の Puma が
    # development モードで起動してスタックトレースを外部公開していた
    # （cure-api #302） (#479)。
    def self.type
      env = [ENV.fetch('RACK_ENV', nil), ENV.fetch('RAILS_ENV', nil)].find {|v| v.to_s.present?}
      return env.to_sym if env
      return Config.instance['/environment'].to_sym
    rescue
      return :development
    end

    def self.development?
      return type.to_s == 'development'
    end

    def self.production?
      return type.to_s == 'production'
    end

    def self.platform
      return :windows if RUBY_PLATFORM.match?(/mswin|msys|mingw|cygwin|bccwin|wince|emc/)
      return :debian if File.executable?('/usr/bin/apt-get')
      return `uname`.chomp.underscore.to_sym
    end

    def self.win?
      return platform == :windows
    end

    def self.ci?
      return ENV['CI'].present? rescue false
    end

    def self.test?
      return ENV['TEST'].present? rescue false
    end

    def self.cron?
      return ENV['CRON'].present? rescue false
    end

    def self.jit?
      return defined?(RubyVM::YJIT)
    end

    def self.cert_file
      return File.join(dir, 'cert/cacert.pem')
    end

    # CA 証明書 (cert/cacert.pem) が最新か。
    #
    # ⚠ **取得に失敗したときに true（＝更新不要）を返さない** (#511)。
    # 取得先が落ちている・`/cert/url` が typo・TLS 検証に失敗した、のいずれも
    # 「鮮度に問題なし」ではない。true に倒すと**古い CA を使い続けることに誰も
    # 気付けず、しかも失敗するほど静かになる**。
    #
    # ⚠ **例外を飲むこと自体は妥当**（鮮度確認に失敗して起動しないのは困る）。
    # 問題は飲んだうえで安全側でない値を返すことなので、値だけ倒す。
    def self.cert_fresh?
      # ⚠ 取得は OS の CA ストアで検証する (#554)。**インスタンスを作ってから**
      # 外すこと（`HTTP#initialize` が env を立てる）。
      http = HTTP.new
      latest = Ginseng.with_system_cert_store {http.get(Config.instance['/cert/url']).body}
      return File.binread(cert_file) == latest
    rescue => e
      warn "cert freshness check failed: #{e.class} #{e.message}"
      return false
    end

    # Gemfile.lock が最新か。
    #
    # ⚠ **確かめられなかったときに true を返さない** (#511)。`cert_fresh?` と
    # 同型で、`rake bundle:check` が「最新」と答えたのに実は何も確かめていない、
    # という状態を作らないため。⚠ **モロヘイヤはこれを CI のゲートに使っている**
    # ので、true に倒すとゲートが黙って no-op になる。
    #
    # ⚠ **「見るものが無い」と「見られなかった」は別。**lock が無い・git の管理下に
    # 無いのは前者なので true のままでよい。
    def self.gem_fresh?
      lock = File.join(dir, 'Gemfile.lock')
      return true unless File.exist?(lock)
      check = CommandLine.new(['git', 'ls-files', 'Gemfile.lock'])
      check.exec
      return true unless check.status.zero? && check.stdout.strip.present?
      before = File.read(lock)
      cmd = CommandLine.new(['bundle', 'lock', '--update'])
      cmd.exec
      unless cmd.status.zero?
        warn "gem freshness check failed: 'bundle lock --update' exited #{cmd.status}"
        return false
      end
      return File.read(lock) == before
    rescue => e
      warn "gem freshness check failed: #{e.class} #{e.message}"
      return false
    ensure
      File.write(lock, before) if before
    end

    def self.tz
      return Time.now.strftime('%:z')
    end

    def self.uid
      return File.stat(dir).uid
    end

    def self.gid
      return File.stat(dir).gid
    end
  end
end
