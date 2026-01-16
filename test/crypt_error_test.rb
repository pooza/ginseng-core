# frozen_string_literal: true
module Ginseng
  class CryptErrorTest < TestCase
    def setup
      raise CryptError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(CryptError, @error)
    end

    def test_status
      assert_equal(403, @error.status)
    end
  end
end
