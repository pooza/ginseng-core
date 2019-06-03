module Ginseng
  class RequestErrorTest < Test::Unit::TestCase
    def setup
      raise RequestError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert(@error.is_a?(RequestError))
    end

    def test_status
      assert_equal(@error.status, 400)
    end
  end
end
