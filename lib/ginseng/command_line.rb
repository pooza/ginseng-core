# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'timeout'
require 'facets/time'

module Ginseng
  class CommandLine
    include Package

    # サブプロセスへ引き継がせない環境変数。詳細は child_env のコメント (#480)。
    UNSET_ENV_KEYS = ['RBENV_VERSION'].freeze

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

    def exec(timeout: nil)
      secs = Time.elapse do
        Bundler.with_unbundled_env do
          block = proc do
            if @user
              @stdout, @stderr, @status = Open3.capture3(sudo_command, chdir: dir)
            else
              @stdout, @stderr, @status = Open3.capture3(child_env, to_s, chdir: dir)
            end
          end
          timeout ? Timeout.timeout(timeout, &block) : block.call
        end
      end
      @pid = @status.pid
      @status = @status.to_i
      log_exec(secs, success: @status.zero?)
      return @status
    end

    def bundle_install
      Bundler.with_unbundled_env do
        return system(child_env, 'bundle', 'install', chdir: dir)
      end
    end

    def exec_system
      start = Time.now
      Bundler.with_unbundled_env do
        if @user
          result = system(sudo_command, chdir: dir)
        else
          result = system(child_env, to_s, chdir: dir)
        end
        log_exec(Time.now - start, success: result)
      end
    end

    private

    # サブプロセスへ渡す環境変数。Bundler.with_unbundled_env が剥がすのは
    # BUNDLE_* / GEM_* / RUBYLIB / RUBYOPT 等「Bundler が設定したもの」だけで、
    # rbenv は管轄外なので RBENV_VERSION は残る。Ruby のパッチアップを跨ぐ
    # デプロイの瞬間、旧 Ruby で稼働中の親（sidekiq 等）から RBENV_VERSION を
    # 引き継いだ子が旧 Ruby で起動し、新 SHA の git gem が materialize されて
    # いない側の gems を見て Bundler::PathError で落ちる (#480)。明示的に unset
    # し、子は .ruby-version / rbenv の通常解決に任せる。
    # 呼び出し側が env で明示指定した場合はそちらを優先する。
    def child_env
      return UNSET_ENV_KEYS.to_h {|key| [key, nil]}.merge(@env.stringify_keys)
    end

    def log_exec(secs, success:)
      params = {
        command: to_s, dir:, env: @env, user: @user,
        status: @status, seconds: secs.round(3)
      }
      success ? @logger.info(params) : @logger.error(params)
    end

    def sudo_command
      parts = ['sudo', '-u', @user, 'env']
      UNSET_ENV_KEYS.each {|key| parts.push('-u', key)}
      @env.stringify_keys.each {|k, v| parts.push("#{k}=#{v}")}
      return [*parts.map(&:shellescape), 'sh', '-c', to_s.shellescape].join(' ')
    end
  end
end
