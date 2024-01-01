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
