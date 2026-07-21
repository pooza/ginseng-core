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
  end
end
