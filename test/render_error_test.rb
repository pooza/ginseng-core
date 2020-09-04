module Ginseng
  class RenderErrorTest < TestCase
    def setup
      raise RenderError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(RenderError, @error)
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
