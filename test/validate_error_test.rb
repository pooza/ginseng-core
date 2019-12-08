module Ginseng
  class ValidateErrorTest < Test::Unit::TestCase
    def setup
      raise ValidateError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert(@error.is_a?(ValidateError))
    end

    def test_status
      assert_equal(@error.status, 422)
    end
  end
end
