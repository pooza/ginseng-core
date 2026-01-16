# frozen_string_literal: true

module Ginseng
  class AuthErrorTest < TestCase
    def setup
      raise AuthError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(AuthError, @error)
    end

    def test_status
      assert_equal(403, @error.status)
    end
  end
end
