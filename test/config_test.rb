module Ginseng
  class ConfigTest < Test::Unit::TestCase
    def setup
      @config = Config.instance
    end

    def test_instance
      assert_true(@config.is_a?(Config))
    end

    def test_version
      assert_equal(@config['/package/version'], Package.version)
    end

    def test_url
      assert_equal(@config['/package/url'], Package.url)
    end
  end
end
