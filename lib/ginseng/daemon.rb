# frozen_string_literal: true

module Ginseng
  class Daemon
    include Package

    attr_reader :pid_file, :working_dir, :app_name

    def initialize(opts = {})
      @logger = logger_class.new
      @config = config_class.instance
      @app_name = opts[:application] || classname
      @working_dir = opts[:working_dir] || environment_class.dir
      @pid_file = File.join(@working_dir, 'tmp', 'pids', "#{@app_name}.pid")
    end

    def name
      return self.class.to_s.split('::').last.sub(/Daemon$/, '').underscore
    end

    def classname
      return self.class.to_s.split('::').last
    end

    def start(args = [])
      save_config
      @logger.info(
        daemon: app_name,
        version: package_class.version,
        message: 'start',
        command: command.to_s,
      )
      exec(command.to_s)
    end

    def stop
      @logger.info(daemon: app_name, version: package_class.version, message: 'stop')
      Process.kill('TERM', 0)
    end

    def command
      raise ImplementError, "'#{__method__}' not implemented"
    end

    def motd
      return self.class.to_s
    end

    def jit?
      return environment_class.jit?
    end

    alias jit_ready? jit?

    def pid
      return File.read(pid_file).to_i if File.file?(pid_file)
      return nil
    end

    def alive?
      return false unless (p = pid)
      Process.kill(0, p)
      return true
    rescue Errno::ESRCH, Errno::EPERM
      return false
    end

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

    def self.spawn!(opts = {}, args = ARGV)
      daemon = new(opts)
      case args.any? && args.shift
      when 'start'
        daemon.send(:run_start, args)
      when 'stop'
        daemon.send(:run_stop)
      when 'restart'
        daemon.send(:run_restart, args)
      when 'status'
        daemon.send(:run_status)
      else
        warn "Usage: #{$PROGRAM_NAME} start|stop|restart|status"
        exit 1
      end
    end

    private

    def write_pid
      File.write(pid_file, Process.pid.to_s)
    end

    def remove_pid
      FileUtils.rm_f(pid_file)
    end

    def run_start(args = [])
      if alive?
        warn "#{app_name} is already running (PID #{pid})"
        exit 1
      end
      puts motd
      write_pid
      trap('TERM') do
        remove_pid
        stop
        exit
      end
      trap('INT') do
        remove_pid
        stop
        exit
      end
      start(args)
    end

    def run_stop
      unless (p = pid)
        warn 'PID file not found. Is the daemon started?'
        exit 1
      end
      remove_pid
      Process.kill('TERM', p)
    rescue Errno::ESRCH
      warn 'PID file found, but process was not running.'
    end

    def run_restart(args = [])
      run_stop if alive?
      sleep 1
      child = fork do
        Process.setsid
        $stdout.reopen(File::NULL, 'w')
        $stderr.reopen(File::NULL, 'w')
        run_start(args)
      end
      Process.detach(child)
    end

    def run_status
      if alive?
        puts "#{app_name} is running (PID #{pid})"
      else
        puts "#{app_name} is not running"
      end
    end
  end
end
