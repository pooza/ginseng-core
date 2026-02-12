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

    def self.type
      return Config.instance['/environment'].to_sym rescue :development
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

    def self.cert_fresh?
      latest = HTTP.new.get(Config.instance['/cert/url']).to_s
      return File.read(cert_file) == latest
    rescue
      return true
    end

    def self.gem_fresh?
      lock = File.join(dir, 'Gemfile.lock')
      return true unless File.exist?(lock)
      before = File.read(lock)
      cmd = CommandLine.new(['bundle', 'lock', '--update'])
      cmd.exec
      return true unless cmd.status.zero?
      return File.read(lock) == before
    rescue
      return true
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
