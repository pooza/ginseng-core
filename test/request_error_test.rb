module Ginseng
  class RequestErrorTest < Test::Unit::TestCase
    def setup
      raise RequestError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(RequestError, @error)
    end

    def test_status
      assert_equal(@error.status, 400)
    end
  end
end
