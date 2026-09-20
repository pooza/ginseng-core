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

    # 記録だけする logger。⚠ **伏せたかどうかは「出た行」でしか測れない**。
    class Recorder
      attr_reader :logs

      def initialize
        @logs = []
      end

      [:error, :warn, :info, :debug, :fatal].each do |severity|
        define_method(severity) do |message = nil|
          @logs.push([severity, message])
          return true
        end
      end
    end

    # 🔴🔴 **引数そのものが資格情報になる (#642)。**
    # ⚠⚠ `Masking#mask` はキー名で判定するので、`command:` の 1 つの文字列には効かない。
    def test_exec_masks_secrets_in_the_command
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      @command.secrets = ['s3cret']
      @command.args = ['echo', 'https://example.com/api/push/s3cret']
      @command.exec

      assert_equal('echo https://example.com/api/push/[FILTERED]', logger.logs.last.last[:command])
    end

    # ⚠⚠ **shellescape した形も伏せる (#642)。** `to_s` はエスケープ済みの文字列を返すので、
    # 🔴 生の形だけ見ていると**クォートされたときに黙って漏れる**。
    def test_masked_covers_the_escaped_form
      @command.secrets = ['a b']

      assert_equal('[FILTERED]', @command.masked('a\ b'))
      assert_equal('[FILTERED]', @command.masked('a b'))
    end

    # 🔴 **`env:` の値も伏せる (#642)。** ⚠⚠ 実測: キー名が `TOKEN` なら上流の
    # `mask` が落とすが、`PUSH_URL` のような名前だと**パスのトークンがそのまま出る**。
    def test_exec_masks_secrets_in_the_env
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      @command.secrets = ['s3cret']
      @command.env = {'PUSH_URL' => 'https://example.com/api/push/s3cret'}
      @command.args = ['echo', 'hello']
      @command.exec

      assert_equal({'PUSH_URL' => 'https://example.com/api/push/[FILTERED]'},
        logger.logs.last.last[:env])
    end

    # ⚠ **渡さなければ従来どおり (#642)。** 🔴 値の型（`nil` など）も変えない。
    def test_exec_leaves_the_env_alone_without_secrets
      logger = Recorder.new
      @command.instance_variable_set(:@logger, logger)
      @command.env = {'EMPTY' => nil}
      @command.args = ['echo', 'hello']
      @command.exec

      assert_equal({'EMPTY' => nil}, logger.logs.last.last[:env])
    end

    # 🔴🔴 **空文字・`nil` は落とす (#642)。**
    # ⚠⚠ 空文字で `gsub` すると**全文字の隙間に `[FILTERED]` が入る**。
    def test_secrets_ignores_blank_values
      @command.secrets = ['', nil, '  ']

      assert_empty(@command.secrets)
      assert_equal('hello', @command.masked('hello'))
    end

    # ⚠⚠ **長いものから伏せる (#642)。** 🔴 短い秘密が長い秘密の一部だと、
    # 先に短いほうを置換して `[FILTERED]def` のような中途半端な形になる。
    def test_masked_prefers_the_longest_secret
      @command.secrets = ['abc', 'abcdef']

      assert_equal('[FILTERED]', @command.masked('abcdef'))
    end

    # 🔴🔴 **正規化を迴回させない (#642 Codex P1)。**
    # ⚠⚠ `secrets << value` を許すと、空文字も順番の崩れも入り込む。
    def test_secrets_cannot_be_mutated_in_place
      @command.secrets = ['abc']

      assert_raise(FrozenError) {@command.secrets << 'abcdef'}
      assert_equal(['abc'], @command.secrets)
    end

    # 🔴 **渡された文字列を持ち回さない (#642 Codex P1)。**
    # ⚠⚠ `to_s` は String に対して自分を返すので、呼び出し側の書き換えが届く。
    def test_secrets_are_decoupled_from_the_caller
      secret = +'s3cret'
      @command.secrets = [secret]
      secret << 'X'

      assert_equal('[FILTERED]', @command.masked('s3cret'))
    end

    # 🔴🔴 **符号化が食い違っても落ちない (#642 Codex P2)。**
    #
    # ⚠⚠ UTF-8 の非 ASCII な秘密を Shift_JIS / BINARY の本文へそのまま当てると
    # `Encoding::CompatibilityError` になり、🔴 **コマンドは成功しているのに
    # `log_exec` が例外を上げる**。
    def test_masked_handles_other_encodings
      @command.secrets = ['秘密']

      assert_equal('コマンド [FILTERED]'.encode('Windows-31J'),
        @command.masked('コマンド 秘密'.encode('Windows-31J')))
      assert_equal('コマンド [FILTERED]'.dup.force_encoding('ASCII-8BIT'),
        @command.masked('コマンド 秘密'.dup.force_encoding('ASCII-8BIT')))
    end

    # ⚠ **その符号化で表せない秘密は、本文に現れようが無い (#642)。**
    # 🔴 飛ばしても伏せ損ねにはならないし、落ちてもいけない。
    def test_masked_skips_a_secret_that_cannot_appear
      @command.secrets = ['秘密']

      assert_equal('hello'.encode('US-ASCII'), @command.masked('hello'.encode('US-ASCII')))
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
