# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

module Ginseng
  # ⚠ `exit` を呼ぶテストはこのプロセスでは走らせられない（このスイートごと巻き込む）ので、
  # 子プロセスで走らせて、要約行と終了コードを見る (#696)。
  class TestCaseTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    # 🔴🔴 **`exit(0)` を呼んだテストがあっても、残りが走り、失敗で終わること (#696)。**
    # 以前は残りが 1 本も走らないまま「0 tests」・終了コード 0 だった。
    def test_exit_in_a_test_is_a_failure
      output, status = run_script(<<~RUBY)
        require 'ginseng'
        module Ginseng
          class ExitingTest < TestCase
            def test_a_exit
              exit(0)
            end

            def test_b_abort
              abort('boom')
            end

            def test_c_after
              assert_true(true)
            end

            def test_d_assert_raise
              assert_raise(SystemExit) {exit(1)}
            end

            def test_e_raise
              raise 'not an exit'
            end
          end

          class ExitingSetupTest < TestCase
            def setup
              exit(3)
            end

            def test_x
              assert_true(true)
            end
          end
        end

        class PlainTest < Test::Unit::TestCase
          def test_plain
            assert_true(true)
          end
        end
      RUBY

      assert_match(/^7 tests, .* 3 failures, 1 errors/, output, '全部走り、exit の 3 本だけが失敗すること')
      assert_match(/RuntimeError: not an exit/, output, 'exit 以外の例外は従来どおり error にすること')
      assert_match(/exit\(0\) が呼ばれた/, output)
      assert_match(/exit\(1\) が呼ばれた \(#696\): boom/, output, 'abort のメッセージを添えること')
      assert_match(/test_x.*exit\(3\) が呼ばれた/, output, 'setup の exit も失敗にすること')
      assert_false(status.success?)
    end

    # ⚠ `Ginseng::TestCase` でないテストの `exit` は従来どおり素通しする（ハンドラはプロセス全体で 1 つ）。
    def test_exit_in_a_plain_test_passes_through
      output, status = run_script(<<~RUBY)
        require 'ginseng'
        Ginseng::TestCase # ⚠ 読み込むと test-unit と例外ハンドラが入る（Zeitwerk の自動読み込み）
        class PlainExitingTest < Test::Unit::TestCase
          def test_exit
            exit(7)
          end
        end
      RUBY

      assert_equal(7, status.exitstatus, output)
    end

    # 🔴 **fork した子の `exit` は受けないこと（4.2.0 リリース前レビュー）。** 受けると子が残りの
    # スイートを丸ごと走らせ、後続のテストが 2 回走った。⚠ 子も test-unit の後始末で「0 tests」の
    # 要約を 1 行出す（v4.1.0 から）ので、要約行の本数では見ない。
    def test_exit_in_a_forked_child_ends_the_child
      output, status = run_script(<<~RUBY)
        require 'ginseng'
        module Ginseng
          class ForkingTest < TestCase
            def test_a_fork
              pid = fork
              exit(0) if pid.nil?
              Process.wait(pid)

              assert_equal(0, $?.exitstatus)
            end

            def test_b_after
              puts "after:\#{Process.pid}"
            end
          end
        end
      RUBY

      assert_equal(1, output.scan(/^after:/).size, output)
      assert_no_match(/exit\(0\) が呼ばれた/, output)
      assert_match(/^2 tests, .* 0 failures, 0 errors/, output)
      assert_predicate(status, :success?, output)
    end

    # 🔴🔴 **読めなかったテストファイルがあれば、失敗で終わること (#696)。** 以前は `- case:` の
    # 1 行だけで、そのファイルのテストは 1 本も走らず終了コードは 0 だった。
    def test_unloadable_test_file_is_a_failure
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'broken_test.rb'), <<~RUBY)
          module Ginseng
            class BrokenTest < UndefinedBaseForTestCaseTest
            end
          end
        RUBY
        File.write(File.join(dir, 'good_test.rb'), <<~RUBY)
          module Ginseng
            class GoodTest < TestCase
              def test_ok
                assert_true(true)
              end
            end
          end
        RUBY
        output, status = run_script(<<~RUBY)
          require 'ginseng'
          Ginseng::TestCase.define_singleton_method(:dir) {#{dir.dump}}
          Ginseng::TestCase.load
        RUBY

        assert_match(/^2 tests, .* 1 failures, 0 errors/, output, '読めたファイルのテストは走ること')
        assert_match(/test_load_broken_test.*broken_test を読めなかった .*UndefinedBaseForTestCaseTest/, output)
        assert_false(status.success?)
      end
    end

    # ⚠ 読めなかったファイルが無ければ、何も足さない。
    def test_load_adds_nothing_without_errors
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'good_test.rb'), <<~RUBY)
          module Ginseng
            class GoodTest < TestCase
              def test_ok
                assert_true(true)
              end
            end
          end
        RUBY
        output, status = run_script(<<~RUBY)
          require 'ginseng'
          Ginseng::TestCase.define_singleton_method(:dir) {#{dir.dump}}
          Ginseng::TestCase.load
        RUBY

        assert_match(/^1 tests, .* 0 failures, 0 errors/, output)
        assert_predicate(status, :success?)
      end
    end

    # 🔴 **意図して飛ばしたファイルは、失敗ではなく omission として数える（pooza/ginseng-style#132）。**
    # 利用側は `rescue` へ落として飛ばしていたので、読めなかったファイルと見分けられなかった。
    def test_skipped_case_is_an_omission
      Dir.mktmpdir do |dir|
        write_good_test(dir)
        File.write(File.join(dir, 'disabled_test.rb'), "raise 'must not be loaded'\n")
        output, status = run_script(<<~RUBY)
          require 'ginseng'
          Ginseng::TestCase.define_singleton_method(:dir) {#{dir.dump}}
          Ginseng::TestCase.define_singleton_method(:skip_case?) {|name| name == 'disabled_test' && 'handler disabled'}
          Ginseng::TestCase.load
          puts "SKIPPED=\#{Ginseng::TestCase::Skipped1Test.public_instance_methods(false).join(',')}"
        RUBY

        assert_match(/^2 tests, .* 0 failures, 0 errors, 0 pendings, 1 omissions/, output)
        assert_match(/^SKIPPED=test_skip_disabled_test$/, output)
        assert_predicate(status, :success?, output)
      end
    end

    # ⚠ omission の詳細は test-unit の出力の設定次第で表示されない（CI では出なかった）ので、
    # 文言は子プロセスの出力ではなく、ここで見る。
    def test_skip_message
      assert_equal(
        'テストファイル disabled_test を読まなかった (skip_case?): handler disabled',
        TestCase.skip_message('disabled_test', 'handler disabled'),
      )
      assert_equal('テストファイル disabled_test を読まなかった (skip_case?)', TestCase.skip_message('disabled_test', true))
    end

    # ⚠ `skip_case?` 自身が例外になったファイルは、読めなかったものとして失敗にする。
    def test_skip_case_error_is_a_failure
      Dir.mktmpdir do |dir|
        write_good_test(dir)
        output, status = run_script(<<~RUBY)
          require 'ginseng'
          Ginseng::TestCase.define_singleton_method(:dir) {#{dir.dump}}
          Ginseng::TestCase.define_singleton_method(:skip_case?) {|_name| raise 'broken skip_case?'}
          Ginseng::TestCase.load
        RUBY

        assert_match(/^1 tests, .* 1 failures, 0 errors/, output)
        assert_match(/good_test を読めなかった .*broken skip_case\?/, output)
        assert_false(status.success?)
      end
    end

    # 🔴🔴 **利用側の `TestCase` は、自分の `Package` / `Environment` で読む（pooza/ginseng-style#132）。**
    # 写しを消せるかの芯。⚠ 字面の `Package` / `Environment` は core のものに解決される。
    def test_load_uses_the_package_of_the_subclass
      Dir.mktmpdir do |root|
        Dir.mkdir(File.join(root, 'test'))
        write_good_test(File.join(root, 'test'))
        output, status = run_script(<<~RUBY)
          require 'ginseng'
          module Foreign
            module Environment
              def self.dir = #{root.dump}
              def self.test? = true
            end

            module Package
              def environment_class = Environment
              def package_class = Package
              def self.name = 'foreign-package'
            end

            class TestCase < Ginseng::TestCase
              include Package
            end
          end
          Foreign::TestCase.load
          puts "TEST=\#{ENV['TEST']}"
        RUBY

        assert_match(/^\+ case: good_test$/, output, '利用側の Environment.dir の test を読み、test? で出力すること')
        assert_match(/^TEST=foreign-package$/, output)
        assert_match(/^1 tests, .* 0 failures, 0 errors/, output)
        assert_predicate(status, :success?, output)
      end
    end

    private

    def write_good_test(dir)
      File.write(File.join(dir, 'good_test.rb'), <<~RUBY)
        module Ginseng
          class GoodTest < TestCase
            def test_ok
              assert_true(true)
            end
          end
        end
      RUBY
    end

    def run_script(source)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'script.rb')
        File.write(path, source)
        lib = File.join(Environment.dir, 'lib')
        output, status = Open3.capture2e(RbConfig.ruby, '-rbundler/setup', '-I', lib, path)
        return [output, status]
      end
    end
  end
end
