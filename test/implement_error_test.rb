module Ginseng
  class ImplementErrorTest < Test::Unit::TestCase
    def setup
      raise ImplementError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_true(@error.is_a?(ImplementError))
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
