module Ginseng
  class HashTest < Test::Unit::TestCase
    def setup
      @hash = {a: 1, b: {c: 2, d: 3}}
    end

    def test_commaize
      assert_equal(@hash.deep_merge(b: {d: 4}, e: 5), {a: 1, b: {c: 2, d: 4}, e: 5})

      @hash.deep_merge!(b: {d: 4}, e: 5, f: 10)
      assert_equal(@hash, {a: 1, b: {c: 2, d: 4}, e: 5, f: 10})
    end
  end
end
