# frozen_string_literal: true

require 'test/unit'

module Ginseng
  class TestCase < Test::Unit::TestCase
    include Package

    # テストを走らせているプロセス。⚠ fork した子と見分けるため（→ 例外ハンドラ）。
    RUNNER_PID = Process.pid

    # 🔴🔴 **テストの途中で `exit` / `abort` が呼ばれたら、そのテストの失敗にして先へ進む (#696)。**
    # test-unit は `SystemExit` を素通しするので、以前は**残りのテストが 1 本も走らないまま**、
    # 終了コードは `exit` に渡した値になった — ⚠⚠ `exit(0)` なら「0 failures・100% passed」の緑
    # （pooza/tomato-shrieker#1667 で 410 本中 137 本しか走っていなかった）。
    #
    # ⚠ setup / teardown の中の `exit` も同じ扱い（test-unit がそこでも例外ハンドラを呼ぶ）。
    # ⚠ 受けるのはテストの外へ漏れたものだけ。`assert_raise(SystemExit)` で受けるテストはそのまま。
    # ⚠⚠ **例外ハンドラはプロセス全体で 1 つの一覧**（test-unit のクラス変数）なので、ここで型を絞る。
    # 🔴 **`exit!` は塞げない** — 例外にならず `at_exit` も飛ばしてその場で終わる。
    # 🔴 **fork した子の `exit` は受けない（4.2.0 リリース前レビュー）。** ブロック無しの `fork` の子で
    # 受けると、**子が残りのスイートを丸ごと走らせ**、副作用（DB・外部への投稿）が二重になった。
    exception_handler do |test, exception|
      next false unless test.is_a?(TestCase) && exception.is_a?(SystemExit)
      next false unless Process.pid == RUNNER_PID
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
    #
    # 🔴 **意図して飛ばすファイルは `skip_case?` で外す（pooza/ginseng-style#132）。** `rescue` へ落として
    # 飛ばすと、読めなかったファイルと見分けられず、失敗として数えられる。
    # ⚠⚠ **利用側は `load` を写さない。** 写すと、ここへ足した検知が届かない（#132 で 12 本が写していた）。
    # 前処理が要るなら `load` を上書きして `super` を呼ぶ。
    def self.load(cases = nil)
      ENV['TEST'] = package_class.name
      errors = {}
      skips = {}
      file_map(cases).each do |name, path|
        if reason = skip_case?(name)
          puts "- case: #{name} (skipped)" if environment_class.test?
          skips[name] = reason
          next
        end
        puts "+ case: #{name}" if environment_class.test?
        require path
      rescue => e
        puts "- case: #{name} (#{e.message})" if environment_class.test?
        errors[name] = e
      end
      report_load_errors(errors)
      report_skipped_cases(skips)
    end

    # 読まずに飛ばすテストファイルか（上書き点・pooza/ginseng-style#132）。真なら読まず、omission として
    # 数える（#488 と同じく、飛ばした本数を要約の行に残す）。⚠ 文字列を返せば理由として添える。
    # ⚠ ここで例外になったファイルは、読めなかったものとして失敗にする。
    def self.skip_case?(_name)
      return false
    end

    # ⚠⚠ **利用側の `Package` / `Environment` は、インスタンスのメソッドから引く。** 利用側の
    # `TestCase` は自分の `Package` を include しているが、その `Package` はクラスへメソッドを
    # 足さない。字面の `Package` / `Environment` は、ここでは常に core のものになる。
    def self.package_class
      return allocate.package_class
    end

    def self.environment_class
      return allocate.environment_class
    end

    # 読めなかったファイルごとに、失敗するテストを 1 本ずつ持つテストケースを作る (#696)。
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
      define_report_case('LoadError', test_case)
    end

    # 飛ばしたファイルごとに、omission になるテストを 1 本ずつ持つテストケースを作る（#132）。
    def self.report_skipped_cases(skips)
      return if skips.empty?
      owner = self
      test_case = Class.new(self) do
        skips.each do |name, reason|
          define_method("test_skip_#{name}") {omit(owner.skip_message(name, reason))}
        end
      end
      define_report_case('Skipped', test_case)
    end

    def self.skip_message(name, reason)
      message = "テストファイル #{name} を読まなかった (skip_case?)"
      message = "#{message}: #{reason}" if reason.is_a?(String)
      return message
    end

    # ⚠ 名前の無いクラスは報告で読めないので、定数として置く（`load` が 2 度呼ばれても上書きしない）。
    def self.define_report_case(prefix, test_case)
      index = 1
      index += 1 while const_defined?("#{prefix}#{index}Test", false)
      const_set("#{prefix}#{index}Test", test_case)
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
      return File.join(environment_class.dir, 'test')
    end
  end
end
