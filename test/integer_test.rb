module Ginseng
  class IntegerTest < TestCase
    def setup
      @number = 4_790_122
    end

    def test_commaize
      assert_equal('4,790,122', @number.commaize)
    end
  end
end
