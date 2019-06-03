# encoding: UTF-8

module Ginseng
  class RedisErrorTest < Test::Unit::TestCase
    def setup
      raise RedisError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert(@error.is_a?(RedisError))
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
