module Ginseng
  class ConfigErrorTest < TestCase
    def setup
      raise ConfigError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(ConfigError, @error)
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
