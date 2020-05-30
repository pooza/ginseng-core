require 'open3'
require 'shellwords'

module Ginseng
  class CommandLine
    include Package
    attr_reader :args
    attr_reader :stdout
    attr_reader :stderr
    attr_reader :status
    attr_reader :pid
    attr_reader :env
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
      start = Time.now
      result = Open3.capture3(@env.stringify_keys, to_s)
      seconds = Time.now - start
      @stdout, @stderr, @status = result
      @pid = @status.pid
      @status = @status.to_i
      if @status.zero?
        @logger.info(command: to_s, env: @env, status: @status, seconds: seconds)
      else
        @logger.error(command: to_s, env: @env, status: @status, seconds: seconds)
      end
      return @status
    end
  end
end
