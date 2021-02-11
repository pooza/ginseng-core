require 'socket'
require 'time'

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
      return Config.instance['/environment'] || 'development'
    end

    def self.development?
      return type == 'development'
    end

    def self.production?
      return type == 'production'
    end

    def self.platform
      return 'Windows' if RUBY_PLATFORM.match?(/mswin|msys|mingw|cygwin|bccwin|wince|emc/)
      return 'Debian' if File.executable?('/usr/bin/apt-get')
      return `uname`.chomp
    end

    def self.win?
      return platform == 'Windows'
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

    def self.cert_file
      return File.join(dir, 'cert/cacert.pem')
    end

    def self.cert_fresh?
      Dir.chdir(dir)
      return `git status`.include?('cacert.pem') == false
    end

    def self.gem_fresh?
      Dir.chdir(dir)
      return `git status`.include?('Gemfile.lock') == false
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
