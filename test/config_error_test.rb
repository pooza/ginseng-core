# encoding: UTF-8

module Ginseng
  class ConfigErrorTest < Test::Unit::TestCase
    def setup
      raise ConfigError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert(@error.is_a?(ConfigError))
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
