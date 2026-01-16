# frozen_string_literal: true

module Ginseng
  class StandardErrorTest < TestCase
    def setup
      @standard_error = StandardError.new('test')
      raise 'test2'
    rescue => e
      @runtime_error = e
    end

    def test_status
      assert_equal(500, @standard_error.status)
      assert_equal(500, @runtime_error.status)
    end

    def test_to_h
      assert_kind_of(Hash, @standard_error.to_h)
      assert_kind_of(Hash, @runtime_error.to_h)
    end
  end
end
