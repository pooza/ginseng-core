# frozen_string_literal: true
module Ginseng
  class NotFoundErrorTest < TestCase
    def setup
      raise NotFoundError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(NotFoundError, @error)
    end

    def test_status
      assert_equal(404, @error.status)
    end
  end
end
