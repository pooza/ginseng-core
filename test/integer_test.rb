module Ginseng
  class IntegerTest < TestCase
    def setup
      @number = 4_790_122
    end

    def test_commaize
      assert_equal(@number.commaize, '4,790,122')
    end
  end
end
