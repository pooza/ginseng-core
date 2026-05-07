# frozen_string_literal: true

module Ginseng
  class ConflictErrorTest < TestCase
    def setup
      raise ConflictError, 'duplicate'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(ConflictError, @error)
    end

    def test_inherits_request_error
      assert_kind_of(RequestError, @error)
    end

    def test_status
      assert_equal(409, @error.status)
    end
  end
end
