module Ginseng
  class AuthErrorTest < Test::Unit::TestCase
    def setup
      raise AuthError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(AuthError, @error)
    end

    def test_status
      assert_equal(@error.status, 403)
    end
  end
end
