module Ginseng
  class IntegerTest < Test::Unit::TestCase
    def commaize
      @number = 4_790_122
    end

    def commaize
      assert_equal(@number.commaize, '4,790,122')
    end
  end
end
