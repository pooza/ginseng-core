# frozen_string_literal: true

require 'tempfile'

module Ginseng
  class ConfigTest < TestCase
    def setup
      @config = Config.instance
    end

    def test_instance
      assert_kind_of(Config, @config)
    end

    def test_raw
      assert_kind_of(Hash, @config.raw)
      @config.raw.each_value do |v|
        assert_kind_of(Hash, v)
      end
    end

    def test_config_error
      assert_raise(ConfigError) do
        @config['/xxxxx']
      end
    end

    # 運用者が config に `founded_on: 2021-03-14` のように日付を素で書いても
    # Psych::DisallowedClass で落ちず Date として読めること（クォート不要）。
    def test_permitted_yaml_classes_allow_dates
      Tempfile.create(['cfg', '.yaml']) do |f|
        f.write("founded_on: 2021-03-14\n")
        f.flush
        classes = Config::PERMITTED_YAML_CLASSES
        loaded = YAML.load_file(f.path, permitted_classes: classes)

        assert_kind_of(Date, loaded['founded_on'])
      end
    end

    # ロード側で許した日付が、検証側で type 違反にならないこと (#481)。
    # JSON Schema に Date を表す型が無いので、生のまま渡すと `type: string` が
    # 必ず違反になる。
    def test_normalize_temporal_keeps_schema_valid
      schema = {'type' => 'object', 'properties' => {'founded_on' => {'type' => 'string'}}}
      raw = {'founded_on' => Date.new(2021, 3, 14)}

      assert_not_empty(JSON::Validator.fully_validate(schema, raw))
      assert_empty(JSON::Validator.fully_validate(schema, @config.normalize_temporal(raw)))
    end

    def test_normalize_temporal
      assert_equal('2021-03-14', @config.normalize_temporal(Date.new(2021, 3, 14)))
      assert_equal(
        {'a' => {'b' => ['2021-03-14']}},
        @config.normalize_temporal({'a' => {'b' => [Date.new(2021, 3, 14)]}}),
      )
      # ⚠⚠ **小数秒を落とさない (#530)。** 引数無しの iso8601 は秒で丸めるので、
      # enum / pattern が秒までの値だけを許していても小数秒付きの値が通っていた。
      # ⚠ 桁は**値が必要とするぶんだけ**（`.5` を `.500` へ揃えない。揃えると
      # 秒までを想定した pattern が落ちる側の問題が形を変えて残る）。
      assert_equal(
        '2021-03-14T12:34:56.5Z',
        @config.normalize_temporal(Time.utc(2021, 3, 14, 12, 34, 56, 500_000)),
      )
      assert_equal(
        '2021-03-14T12:34:56.123456Z',
        @config.normalize_temporal(Time.utc(2021, 3, 14, 12, 34, 56, 123_456)),
      )
      # ⚠⚠ **10 桁以上でも切り詰めない (#550)。** 切り詰めると「検証した値」と
      # 「Config が返す値」が食い違い、#530 が消そうとした穴が再現する。
      assert_equal(
        '2021-03-14T12:34:56.1234567891Z',
        @config.normalize_temporal(Time.utc(2021, 3, 14, 12, 34, 56 + Rational(1_234_567_891, 10**10))),
      )
      # ⚠ 10 進で表せない分母（DateTime の演算で作れる）でも止まること。
      assert_nothing_raised do
        Timeout.timeout(5) do
          @config.normalize_temporal(DateTime.new(2021, 3, 14, 12, 34, Rational(1, 3)))
        end
      end
      # ⚠ 持っていない値に .000 を足さない（秒までを想定した pattern が落ちる）。
      assert_equal(
        '2021-03-14T12:34:56Z',
        @config.normalize_temporal(Time.utc(2021, 3, 14, 12, 34, 56)),
      )
      assert_equal(
        '2021-03-14T12:34:56+00:00',
        @config.normalize_temporal(DateTime.new(2021, 3, 14, 12, 34, 56)),
      )
      assert_equal(
        '2021-03-14T12:34:56.5+00:00',
        @config.normalize_temporal(DateTime.new(2021, 3, 14, 12, 34, Rational(565, 10))),
      )
      assert_equal('hoge', @config.normalize_temporal('hoge'))
      assert_equal(1, @config.normalize_temporal(1))
      assert_nil(@config.normalize_temporal(nil))
    end

    def test_keys
      assert_equal(@config.keys('/package'), ['authors', 'description', 'email', 'license', 'url', 'version'].to_set)
    end

    def test_schema
      assert_kind_of(Hash, @config.schema) unless Environment.ci?
    end

    def test_errors
      assert_kind_of(Array, @config.errors) unless Environment.ci?
    end

    def test_version
      assert_equal(@config['/package/version'], Package.version)
    end

    def test_url
      assert_equal(@config['/package/url'], Package.url)
    end

    def test_local_file_path
      assert_kind_of(String, @config.local_file_path)
      assert_path_exist(@config.local_file_path)
    end

    def test_update_file
      @config.update_file(hoge: {fuga: 1})
      local_config = YAML.load_file(@config.local_file_path)

      assert_equal(1, local_config.dig('hoge', 'fuga'))
      @config.update_file(hoge: {fuga: 2})
      local_config = YAML.load_file(@config.local_file_path)

      assert_equal(2, local_config.dig('hoge', 'fuga'))
      @config.update_file(hoge: nil)
      local_config = YAML.load_file(@config.local_file_path)

      assert_nil(local_config.dig('hoge', 'fuga'))
    end

    def test_deep_merge
      config = Config.deep_merge({}, {a: 111, b: 222})

      assert_equal({'a' => 111, 'b' => 222}, config)
      config = Config.deep_merge(config, {c: {d: 333, e: 444}})

      assert_equal({'a' => 111, 'b' => 222, 'c' => {'d' => 333, 'e' => 444}}, config)
      config = Config.deep_merge(config, {c: {e: 333, f: 444}})

      assert_equal({'a' => 111, 'b' => 222, 'c' => {'d' => 333, 'e' => 333, 'f' => 444}}, config)
      config = Config.deep_merge(config, {c: {d: nil}})

      assert_equal({'a' => 111, 'b' => 222, 'c' => {'e' => 333, 'f' => 444}}, config)
    end

    def test_load_file
      assert_kind_of(Hash, Config.load_file('autoload'))
    end

    # reload がサブクラスの load を呼ぶこと (#491)。alias reload load だと定義時点の
    # Ginseng::Config#load が束縛され、サブクラスが load で足した設定が reload 後に
    # 消える。Singleton を挟まず素の Class.new で動的束縛だけを見る。
    def test_reload_calls_overridden_load
      klass = Class.new(Config) do
        include Singleton

        attr_reader :load_count

        def load
          @load_count = (@load_count || 0) + 1
          self['/subclass_key'] = 'loaded'
        end
      end
      instance = klass.instance

      assert_equal(1, instance.load_count, '初期化で 1 回だけ load される')
      instance['/subclass_key'] = nil
      instance.reload

      assert_equal(2, instance.load_count, 'reload でサブクラスの load が呼ばれる')
      assert_equal('loaded', instance['/subclass_key'], 'サブクラスが足した設定が残る')
    end
  end
end
