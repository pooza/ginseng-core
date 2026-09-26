# frozen_string_literal: true

module Ginseng
  # 設定の書き出し (#651)。
  #
  # 🔴🔴 **芯は「既存のファイルに書かない」こと。** 旧版の `File.write` は、
  # `<name>.yaml` が symlink ならリンク先を YAML で上書きし、mode は umask 任せ
  # （`022` なら誰でも読める `0644`）だった。中身には資格情報が入りうる。
  class DaemonConfigCacheTest < TestCase
    # ⚠ 本物の `config_cache_path` はアプリのディレクトリ（`Environment.dir`）を指すので、
    # 書き出し先だけテスト用のディレクトリへ向ける。
    class Stub < Daemon
      def command
        return 'true'
      end

      def config_cache_path
        return File.join(working_dir, "tmp/cache/#{name}.yaml")
      end
    end

    def setup
      @dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(@dir, 'tmp/cache'))
      @daemon = Stub.new({application: 'GinsengConfigCacheTest', working_dir: @dir})
    end

    def teardown
      super
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    def test_writes_the_body
      write('a: 1')

      assert_equal('a: 1', File.read(@daemon.config_cache_path))
    end

    # ⚠ **umask に関係なく `0600` を超えない。** 🔴 umask `0` でも広がらないこと。
    def test_mode_is_private_regardless_of_umask
      old = File.umask(0)
      begin
        write('a: 1')
      ensure
        File.umask(old)
      end

      assert_equal(0o600, File.stat(@daemon.config_cache_path).mode & 0o777)
    end

    # 🔴 **umask で削られても `0600` に戻す (#659 Codex P2)。** 読み戻すのは本人なので、
    # 所有者の読み取りが落ちると `YAML.load_file` が失敗する。⚠ root で走る CI では
    # 読めてしまうので、読めるかではなく mode で測る。
    def test_mode_is_not_narrowed_by_umask
      old = File.umask(0o477)
      begin
        write('a: 1')
      ensure
        File.umask(old)
      end

      assert_equal(0o600, File.stat(@daemon.config_cache_path).mode & 0o777)
    end

    # ⚠ 既にある（旧版が `0644` で書いた）ファイルも、置き換えれば `0600` になる。
    def test_replaces_an_existing_world_readable_file
      path = @daemon.config_cache_path
      File.write(path, 'old')
      File.chmod(0o644, path)

      write('new')

      assert_equal('new', File.read(path))
      assert_equal(0o600, File.stat(path).mode & 0o777)
    end

    # 🔴🔴 **symlink の先を上書きしない。** 名前（symlink そのもの）が置き換わる。
    def test_does_not_follow_a_symlinked_cache_file
      victim = File.join(@dir, 'victim')
      File.write(victim, 'secret')
      File.symlink(victim, @daemon.config_cache_path)

      write('a: 1')

      assert_equal('secret', File.read(victim), 'リンク先のファイルを壊さないこと')
      assert_false(File.symlink?(@daemon.config_cache_path))
      assert_equal('a: 1', File.read(@daemon.config_cache_path))
    end

    # 🔴 **`tmp/cache` を他所へのリンクにされると、書いた設定をそのまま読まれる。**
    def test_refuses_when_the_cache_dir_is_a_symlink
      elsewhere = File.join(@dir, 'elsewhere')
      FileUtils.mkdir_p(elsewhere)
      cache = File.join(@dir, 'tmp/cache')
      FileUtils.remove_entry(cache)
      File.symlink(elsewhere, cache)

      error = assert_raise(ConfigError) {write('a: 1')}
      assert_match(/#{Regexp.escape(cache)}'/, error.message)
      assert_empty(Dir.children(elsewhere), 'リンク先に何も作らないこと')
    end

    # ⚠⚠ **最終要素だけ見ても足りない**（#632 Codex P1 と同じ形）。`tmp` の側を
    # symlink にすれば、`tmp/cache` は本物のディレクトリなので検査を通る。
    def test_refuses_when_an_ancestor_is_a_symlink
      elsewhere = File.join(@dir, 'elsewhere')
      FileUtils.mkdir_p(File.join(elsewhere, 'cache'))
      FileUtils.remove_entry(File.join(@dir, 'tmp'))
      File.symlink(elsewhere, File.join(@dir, 'tmp'))

      error = assert_raise(ConfigError) {write('a: 1')}
      assert_match(/#{Regexp.escape(File.join(@dir, 'tmp'))}'/, error.message)
      assert_empty(Dir.children(File.join(elsewhere, 'cache')), 'リンク先に何も作らないこと')
    end

    # ⚠ **置けなかったら、自分が作った一時ファイルは残さない。**
    def test_leaves_no_temp_file_when_it_cannot_install
      FileUtils.mkdir_p(File.join(@daemon.config_cache_path, 'occupied'))

      assert_raise_kind_of(SystemCallError) {write('a: 1')}
      assert_equal(
        [File.basename(@daemon.config_cache_path)],
        Dir.children(File.join(@dir, 'tmp/cache')),
      )
    end

    private

    def write(body)
      @daemon.send(:write_config_cache, body)
    end
  end
end
