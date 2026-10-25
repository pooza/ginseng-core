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

      assert_match(/^6 tests, .* 3 failures, 0 errors/, output, '全部走り、exit の 3 本だけが失敗すること')
      assert_match(/exit\(0\) が呼ばれた/, output)
      assert_match(/exit\(1\) が呼ばれた \(#696\): boom/, output, 'abort のメッセージを添えること')
      assert_match(/test_x.*exit\(3\) が呼ばれた/, output, 'setup の exit も失敗にすること')
      assert_false(status.success?)
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

    private

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
