module Ginseng
  class StandardErrorTest < TestCase
    def setup
      @standard_error = StandardError.new('test')
      raise 'test2'
    rescue => e
      @runtime_error = e
    end

    def test_status
      assert_equal(@standard_error.status, 500)
      assert_equal(@runtime_error.status, 500)
    end

    def test_to_h
      assert_kind_of(Hash, @standard_error.to_h)
      assert_kind_of(Hash, @runtime_error.to_h)
    end
  end
end
