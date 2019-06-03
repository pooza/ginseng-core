module Ginseng
  class RenderErrorTest < Test::Unit::TestCase
    def setup
      raise RenderError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert(@error.is_a?(RenderError))
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
