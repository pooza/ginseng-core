require 'open3'
require 'shellwords'

module Ginseng
  class CommandLine
    include Package
    attr_reader :args
    attr_reader :stdout
    attr_reader :stderr
    attr_reader :status

    def initialize(args = [])
      @logger = logger_class.new
      self.args = args
    end

    def args=(args)
      @args = args.to_a
      @stdout = nil
      @stderr = nil
      @status = nil
    end

    def to_s
      return args.map(&:shellescape).join(' ')
    end

    def exec
      start = Time.now
      result = Open3.capture3(to_s)
      seconds = Time.now - start
      @stdout = result[0].to_s
      @stderr = result[1].to_s
      @status = result[2].to_i
      if @status.zero?
        @logger.info(command: to_s, status: @status, seconds: seconds)
      else
        @logger.error(command: to_s, status: @status, seconds: seconds)
      end
      return @status
    end
  end
end
