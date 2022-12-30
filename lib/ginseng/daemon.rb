require 'daemon_spawn'

module Ginseng
  class Daemon < DaemonSpawn::Base
    include Package

    def initialize(opts = {})
      @logger = logger_class.new
      @config = config_class.instance
      opts[:application] ||= classname
      opts[:working_dir] ||= environment_class.dir
      super
    end

    def name
      return self.class.to_s.split('::').last.sub(/Daemon$/, '').underscore
    end

    def start(args)
      save_config
      @logger.info(daemon: app_name, version: package_class.version, message: 'start')
      IO.popen(command.to_s, {err: [:child, :out]}).each_line do |line|
        @logger.info(create_log_entry(line))
      end
    end

    def stop
      @logger.info(daemon: app_name, version: package_class.version, message: 'stop')
      Process.kill('KILL', 0)
    end

    def command
      raise ImplementError, "'#{__method__}' not implemented"
    end

    def motd
      return self.class.to_s
    end

    def jit_ready?
      return ENV['RUBY_YJIT_ENABLE'].present?
    end

    def fork!(args)
      Process.setsid
      exit if fork
      File.write(pid_file, Process.pid.to_s)
      Dir.chdir(working_dir)
      trap('TERM') do
        stop
        exit
      end
      start(args)
    end

    def self.start(opts, args)
      living_daemons = find(opts).select(&:alive?)
      raise "Already started! PIDS: #{living_daemons.map(&:pid).join(', ')}" if living_daemons.any?
      build(opts).map do |daemon|
        unless File.writable?(File.dirname(daemon.pid_file))
          raise "Unable to write PID file to #{daemon.pid_file}"
        end
        raise "#{daemon.app_name} is already running (PID #{daemon.pid})" if daemon.alive?
        fork {daemon.fork!(args)}
        puts daemon.motd
        puts ''
      end
    end

    private

    def save_config
      config = @config.raw['application'][name]
      if values = @config.raw['local']&.dig(name)
        config.deep_merge!(values)
      end
      File.write(config_cache_path, config.to_yaml)
    end

    def config_cache_path
      return File.join(environment_class.dir, "tmp/cache/#{name}.yaml")
    end

    def create_log_entry(line)
      return {daemon: app_name, output: line.chomp}
    end
  end
end
