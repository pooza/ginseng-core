# frozen_string_literal: true

module Ginseng
  class ValidateErrorTest < TestCase
    def setup
      raise ValidateError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(ValidateError, @error)
    end

    def test_status
      assert_equal(422, @error.status)
    end
  end
end
