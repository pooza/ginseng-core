# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'facets/time'

module Ginseng
  class CommandLine
    include Package

    attr_reader :args, :stdout, :stderr, :status, :pid, :env
    attr_accessor :dir, :user

    def initialize(args = [])
      @logger = logger_class.new
      @env = {}
      @user = nil
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
      return args.map do |arg|
        arg.is_a?(Symbol) ? arg : arg.to_s.shellescape
      end.join(' ')
    end

    def exec
      secs = Time.elapse do
        Bundler.with_unbundled_env do
          if @user
            @stdout, @stderr, @status = Open3.capture3(sudo_command, chdir: dir)
          else
            @stdout, @stderr, @status = Open3.capture3(@env.stringify_keys, to_s, chdir: dir)
          end
        end
      end
      @pid = @status.pid
      @status = @status.to_i
      if @status.zero?
        @logger.info(command: to_s, dir:, env: @env, user: @user, status: @status,
          seconds: secs.round(3))
      else
        @logger.error(command: to_s, dir:, env: @env, user: @user, status: @status,
          seconds: secs.round(3))
      end
      return @status
    end

    def bundle_install
      Bundler.with_unbundled_env do
        return system(@env.stringify_keys, 'bundle', 'install', chdir: dir)
      end
    end

    def exec_system
      start = Time.now
      Bundler.with_unbundled_env do
        if @user
          result = system(sudo_command, chdir: dir)
        else
          result = system(@env.stringify_keys, to_s, chdir: dir)
        end
        if result
          @logger.info(command: to_s, dir:, env: @env, user: @user,
            seconds: (Time.now - start).round(3))
        else
          @logger.error(command: to_s, dir:, env: @env, user: @user,
            seconds: (Time.now - start).round(3))
        end
      end
    end

    private

    def sudo_command
      parts = ['sudo', '-u', @user]
      if @env.any?
        parts.push('env')
        @env.stringify_keys.each {|k, v| parts.push("#{k}=#{v}")}
      end
      return [*parts.map(&:shellescape), to_s].join(' ')
    end
  end
end
