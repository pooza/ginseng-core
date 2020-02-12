require 'daemon_spawn'

module Ginseng
  class Daemon < DaemonSpawn::Base
    include Package

    def initialize(opts = {})
      @logger = logger_class.new
      @config = config_class.instance
      opts[:application] ||= classname
      opts[:working_dir] ||= environment_class.dir
      super(opts)
    end

    def start(args)
      IO.popen(command.to_s, {err: [:child, :out]}).each_line do |line|
        @logger.info(daemon: app_name, output: line.chomp)
      end
    end

    def stop
      Process.kill('KILL', child_pid)
    end

    def command
      raise Ginseng::ImplementError, "'#{__method__}' not implemented"
    end

    def child_pid
      return 0
    end

    def motd
      return self.class.to_s
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
        fork do
          daemon.fork!(args)
        end
        puts daemon.motd
      end
    end
  end
end
