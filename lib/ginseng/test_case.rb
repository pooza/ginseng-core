# frozen_string_literal: true

require 'test/unit'

module Ginseng
  class TestCase < Test::Unit::TestCase
    include Package

    # 🔴🔴 **テストの途中で `exit` / `abort` が呼ばれたら、そのテストの失敗にして先へ進む (#696)。**
    # test-unit は `SystemExit` を素通しするので、以前は**残りのテストが 1 本も走らないまま**、
    # 終了コードは `exit` に渡した値になった — ⚠⚠ `exit(0)` なら「0 failures・100% passed」の緑
    # （pooza/tomato-shrieker#1667 で 410 本中 137 本しか走っていなかった）。
    #
    # ⚠ setup / teardown の中の `exit` も同じ扱い（test-unit がそこでも例外ハンドラを呼ぶ）。
    # ⚠ 受けるのはテストの外へ漏れたものだけ。`assert_raise(SystemExit)` で受けるテストはそのまま。
    # ⚠⚠ **例外ハンドラはプロセス全体で 1 つの一覧**（test-unit のクラス変数）なので、ここで型を絞る。
    # 🔴 **`exit!` は塞げない** — 例外にならず `at_exit` も飛ばしてその場で終わる。
    exception_handler do |test, exception|
      next false unless test.is_a?(TestCase) && exception.is_a?(SystemExit)
      test.__send__(:add_exit_failure, exception)
      next true
    end

    def underscore
      return self.class.to_s.split('::').last.underscore.sub(/_test$/, '')
    end

    def disable?
      return false
    end

    # disable? のケースは omission として報告する。単に実行を飛ばすと test-unit は
    # 「.」＝ pass として集計するため、前提（DB・外部サービス・アカウント等）を
    # 満たさない環境では 1 行も実行されていないのに 100% passed と出て、
    # 「守れているつもりの緑」になる (#488)。
    def run_test
      return omit("#{self.class}: 前提を満たさないためスキップ (disable?)") if disable?
      super
    end

    # その設定が在るか。⚠ **無い前提を「落ちる」ではなく「飛ばす」へ倒す**ための
    # 判定 (#508)。⚠⚠ **シークレットを要求するテストは、CI では動かせないだけで
    # 壊れているわけではない。** 落とすと赤が常態化し、本物の回帰が埋もれる。
    #
    # ⚠ 値そのものは見ない（`ConfigError` を真偽値へ落とすのが目的）。
    def config?(key)
      return config_class.instance[key].present?
    rescue ConfigError
      return false
    end

    # ⚠ `abort` も `SystemExit`（status 1）なので、メッセージは例外のものを添える。
    def add_exit_failure(exception)
      message = "テストの途中で exit(#{exception.status}) が呼ばれた (#696)"
      message = "#{message}: #{exception.message}" unless exception.message == 'exit'
      add_failure(message, exception.backtrace || caller)
    end

    def fixture(name)
      return File.read(File.join(self.class.fixture_dir, name))
    end

    def json_fixture(name)
      return JSON.parse(fixture(name))
    end

    def self.fixture_dir
      return File.join(dir, 'fixture')
    end

    # 🔴🔴 **読めなかったテストファイルは、失敗するテストとして報告する (#696)。** 以前は `- case:` の
    # 1 行を出して先へ進むだけで、**そのファイルのテストが 1 本も走らないまま終了コードは 0** だった。
    # ⚠ 他のファイルは従来どおり読み進める（1 つの不備で全部を止めない）。
    # ⚠ `rescue => e` が受けるのは `StandardError`（未定義の定数など）。構文エラーや `LoadError` は
    # `ScriptError` なので、従来どおりその場で止まる（黙らない）。
    def self.load(cases = nil)
      ENV['TEST'] = Package.name
      errors = {}
      file_map(cases).each do |name, path|
        puts "+ case: #{name}" if Environment.test?
        require path
      rescue => e
        puts "- case: #{name} (#{e.message})" if Environment.test?
        errors[name] = e
      end
      report_load_errors(errors)
    end

    # 読めなかったファイルごとに、失敗するテストを 1 本ずつ持つテストケースを作る (#696)。
    # ⚠ 名前の無いクラスは報告で読めないので、定数として置く（`load` が 2 度呼ばれても上書きしない）。
    def self.report_load_errors(errors)
      return if errors.empty?
      test_case = Class.new(self) do
        errors.each do |name, error|
          define_method("test_load_#{name}") do
            failure = Test::Unit::AssertionFailedError.new(
              "テストファイル #{name} を読めなかった (#696): #{error.class}: #{error.message}",
            )
            failure.set_backtrace(error.backtrace || caller)
            raise failure
          end
        end
      end
      index = 1
      index += 1 while const_defined?("LoadError#{index}Test", false)
      const_set("LoadError#{index}Test", test_case)
    end

    def self.names(cases = nil)
      return file_map(cases).keys.to_set
    end

    def self.file_map(cases = nil)
      finder = FileFinder.new
      finder.dir = dir
      finder.patterns.push('*.rb')
      all = finder.exec.to_h {|path| [File.basename(path, '.rb'), path]}
      return all unless cases
      targets = cases.split(',').map(&:underscore)
        .map {|v| [v, "#{v}_test", v.sub(/_test$/, '')]}.flatten.compact
      return all.slice(*targets)
    end

    def self.dir
      return File.join(Environment.dir, 'test')
    end
  end
end
