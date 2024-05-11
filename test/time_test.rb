module Ginseng
  class TimeTest < TestCase
    def test_today?
      assert_false(Time.parse('2000/01/01 00:00').today?)
      assert_false(Time.parse('1970/01/01 00:00').today?)
      assert_predicate(Time.now, :today?)
    end
  end
end
