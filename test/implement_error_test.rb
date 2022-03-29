module Ginseng
  class ImplementErrorTest < TestCase
    def setup
      raise ImplementError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(ImplementError, @error)
    end

    def test_status
      assert_equal(500, @error.status)
    end
  end
end
