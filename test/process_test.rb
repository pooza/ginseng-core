module Ginseng
  class ProcessTest < Test::Unit::TestCase
    def test_alive?
      assert(Process.alive?(0))
      assert_false(Process.alive?(-2))
    end
  end
end
