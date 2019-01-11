module Ginseng
  class DatabaseErrorTest < Test::Unit::TestCase
    def setup
      raise DatabaseError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_true(@error.is_a?(DatabaseError))
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
