require 'open3'
require 'shellwords'
require 'facets/time'

module Ginseng
  class CommandLine
    include Package
    attr_reader :args, :stdout, :stderr, :status, :pid, :env
    attr_accessor :dir

    def initialize(args = [])
      @logger = logger_class.new
      @env = {}
      @dir = environment_class.dir
      self.args = args
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
      return args.map(&:to_s).map(&:shellescape).join(' ')
    end

    def exec
      secs = Time.elapse do
        Bundler.with_unbundled_env do
          Dir.chdir(dir) if dir
          @stdout, @stderr, @status = Open3.capture3(@env.stringify_keys, to_s)
        end
      end
      @pid = @status.pid
      @status = @status.to_i
      if @status.zero?
        @logger.info(command: to_s, env: @env, status: @status, seconds: secs.round(3))
      else
        @logger.error(command: to_s, env: @env, status: @status, seconds: secs.round(3))
      end
      return @status
    end

    def exec_system
      start = Time.now
      Bundler.with_unbundled_env do
        Dir.chdir(dir) if dir
        if system(@env.stringify_keys, to_s)
          @logger.info(command: to_s, env: @env, seconds: (Time.now - start).round(3))
        else
          @logger.error(command: to_s, env: @env, seconds: (Time.now - start).round(3))
        end
      end
    end
  end
end
