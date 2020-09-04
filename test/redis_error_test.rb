module Ginseng
  class RedisErrorTest < TestCase
    def setup
      raise RedisError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(RedisError, @error)
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
