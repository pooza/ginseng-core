# frozen_string_literal: true
module Ginseng
  class ProcessTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def test_alive?
      assert(Process.alive?(0))
      assert_false(Process.alive?(-2))
    end
  end
end
