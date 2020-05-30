module Ginseng
  class CommandLineTest < Test::Unit::TestCase
    def setup
      @command = CommandLine.new
    end

    def test_args
      @command.args = []
      assert_equal(@command.args, [])
      @command.args = ['ffmpeg', File.join(Environment.dir, 'sample/poyke.mp4')]
      assert_equal(@command.args[0], 'ffmpeg')
    end

    def test_to_s
      @command.args = ['ls', 'a b', '"x"']
      assert_equal(@command.to_s, 'ls a\\ b \\"x\\"')
    end

    def test_dir
      assert_nil(@command.dir)
      @command.dir = '/etc'
      @command.args = ['ls']
      @command.exec
      assert_equal(Dir.pwd, '/etc')
    end

    def test_exec
      @command.args = ['ls', '/']
      @command.exec
      assert(@command.status.zero?)
      assert(@command.stdout.present?)
      assert(@command.stderr.blank?)
      assert_kind_of(Integer, @command.pid)
    end

    def test_env
      @command.env = {HOGE: 'fugafuga'}
      @command.args = ['env']
      @command.exec
      assert(@command.stdout.include?('HOGE=fugafuga'))
    end
  end
end
