module Ginseng
  class GatewayErrorTest < TestCase
    def setup
      raise GatewayError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(GatewayError, @error)
    end

    def test_status
      assert_equal(502, @error.status)
    end

    def test_source_status
      assert_equal(502, @error.status)
    end
  end
end
