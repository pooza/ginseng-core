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
      @command.args = ['ls']
      @command.exec

      assert_equal('/etc', Dir.pwd)
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

    def test_env
      @command.env = {HOGE: 'fugafuga'}
      @command.args = ['env']
      @command.exec

      assert_includes(@command.stdout, 'HOGE=fugafuga')
    end
  end
end
