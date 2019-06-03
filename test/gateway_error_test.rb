module Ginseng
  class GatewayErrorTest < Test::Unit::TestCase
    def setup
      raise GatewayError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert(@error.is_a?(GatewayError))
    end

    def test_status
      assert_equal(@error.status, 502)
    end
  end
end
