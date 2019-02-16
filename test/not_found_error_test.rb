module Ginseng
  class NotFoundErrorTest < Test::Unit::TestCase
    def setup
      raise NotFoundError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert(@error.is_a?(NotFoundError))
    end

    def test_status
      assert_equal(@error.status, 404)
    end
  end
end
