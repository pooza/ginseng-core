# frozen_string_literal: true
module Ginseng
  class DatabaseErrorTest < TestCase
    def setup
      raise DatabaseError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(DatabaseError, @error)
    end

    def test_status
      assert_equal(500, @error.status)
    end
  end
end
