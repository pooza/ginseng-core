# frozen_string_literal: true

module Ginseng
  class CommandLineTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @command = CommandLine.new
    end

    def test_args
      @command.args = []

      assert_empty(@command.args)
      @command.args = ['ffmpeg', File.join(Environment.dir, 'sample/poyke.mp4')]

      assert_equal('ffmpeg', @command.args[0])
    end

    def test_to_s
      @command.args = ['ls', 'a b', '"x"']

      assert_equal('ls a\\ b \\"x\\"', @command.to_s)
    end

    def test_dir
      assert_equal(@command.dir, Environment.dir)
      @command.dir = '/etc'
      @command.args = ['pwd']
      @command.exec

      # chdir が効くのは子プロセスだけ。親の Dir.pwd を見ていたため、この
      # アサーションは導入以来ずっと落ちていた。
      assert_equal('/etc', @command.stdout.chomp)
    end

    def test_exec
      @command.args = ['ls', '/']
      @command.exec

      assert_predicate(@command.status, :zero?)
      assert_predicate(@command.stdout, :present?)
      assert_predicate(@command.stderr, :blank?)
      assert_kind_of(Integer, @command.pid)
    end

    def test_exec_system
      @command.args = ['ls', '/']

      assert(@command.exec_system)
    end

    def test_bundle_install
      @command.dir = Environment.dir

      assert(@command.bundle_install)
    end

    def test_exec_with_timeout
      @command.args = ['ls', '/']
      @command.exec(timeout: 10)

      assert_predicate(@command.status, :zero?)
      assert_predicate(@command.stdout, :present?)
    end

    def test_exec_timeout_expired
      @command.args = ['sleep', '10']

      assert_raise(Timeout::Error) do
        @command.exec(timeout: 1)
      end
    end

    def test_env
      @command.env = {HOGE: 'fugafuga'}
      @command.args = ['env']
      @command.exec

      assert_includes(@command.stdout, 'HOGE=fugafuga')
    end

    # Ruby パッチアップを跨ぐデプロイで、旧 Ruby の親から引き継いだ
    # RBENV_VERSION が子を旧 Ruby へ倒すのを防ぐ (#480)。
    def test_exec_does_not_inherit_rbenv_version
      original = ENV.fetch('RBENV_VERSION', nil)
      ENV['RBENV_VERSION'] = '0.0.0-should-not-leak'
      @command.args = ['env']
      @command.exec

      assert_not_includes(@command.stdout, 'RBENV_VERSION=')
    ensure
      ENV['RBENV_VERSION'] = original
    end

    # 呼び出し側が明示指定した場合はそちらを優先する。
    def test_env_overrides_unset
      @command.env = {RBENV_VERSION: '3.4.9'}
      @command.args = ['env']
      @command.exec

      assert_includes(@command.stdout, 'RBENV_VERSION=3.4.9')
    end

    def test_sudo_command_unsets_rbenv_version
      @command.user = 'nobody'
      @command.args = ['env']

      assert_includes(@command.send(:sudo_command), 'env -u RBENV_VERSION')
    end
  end
end
