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
      return args.map(&:shellescape).join(' ')
    end

    def exec
      Dir.chdir(dir) if dir
      result = nil
      secs = Time.elapse do
        Bundler.with_unbundled_env do
          result = Open3.capture3(@env.stringify_keys, to_s)
        end
      end
      @stdout, @stderr, @status = result
      @pid = @status.pid
      @status = @status.to_i
      if @status.zero?
        @logger.info(command: to_s, env: @env, status: @status, seconds: secs.round(3))
      else
        @logger.error(command: to_s, env: @env, status: @status, seconds: secs.round(3))
      end
      return @status
    end
  end
end
