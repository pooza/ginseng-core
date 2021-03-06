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
      @config.raw.each do |k, v|
        assert_kind_of(Hash, v)
      end
    end

    def test_config_error
      assert_raise(ConfigError) do
        @config['/xxxxx']
      end
    end

    def test_keys
      assert_equal(@config.keys('/package'), ['authors', 'description', 'email', 'license', 'url', 'version'])
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

    def test_deep_merge
      config = Config.deep_merge({}, {a: 111, b: 222})
      assert_equal(config, {'a' => 111, 'b' => 222})
      config = Config.deep_merge(config, {c: {d: 333, e: 444}})
      assert_equal(config, {'a' => 111, 'b' => 222, 'c' => {'d' => 333, 'e' => 444}})
      config = Config.deep_merge(config, {c: {e: 333, f: 444}})
      assert_equal(config, {'a' => 111, 'b' => 222, 'c' => {'d' => 333, 'e' => 333, 'f' => 444}})
      config = Config.deep_merge(config, {c: {d: nil}})
      assert_equal(config, {'a' => 111, 'b' => 222, 'c' => {'e' => 333, 'f' => 444}})
    end
  end
end
