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
      cmd = CommandLine.new(['git', 'diff', '--name-only', 'HEAD', '--', 'cert/cacert.pem'])
      cmd.exec
      return false unless cmd.status.zero?
      cmd.stdout.strip.empty?
    end

    def self.gem_fresh?
      check = CommandLine.new(['git', 'ls-files', 'Gemfile.lock'])
      check.exec
      return true unless check.status.zero? && check.stdout.strip.present?
      cmd = CommandLine.new(['git', 'diff', '--name-only', 'HEAD', '--', 'Gemfile.lock'])
      cmd.exec
      return false unless cmd.status.zero?
      cmd.stdout.strip.empty?
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
