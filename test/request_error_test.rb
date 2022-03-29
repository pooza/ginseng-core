module Ginseng
  class RequestErrorTest < TestCase
    def setup
      raise RequestError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(RequestError, @error)
    end

    def test_status
      assert_equal(400, @error.status)
    end
  end
end
