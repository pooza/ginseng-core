module Ginseng
  class DatabaseErrorTest < Test::Unit::TestCase
    def setup
      raise DatabaseError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(DatabaseError, @error)
    end

    def test_status
      assert_equal(@error.status, 500)
    end
  end
end
