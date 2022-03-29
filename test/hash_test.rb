module Ginseng
  class HashTest < TestCase
    def setup
      @hash = {a: 1, b: {c: 2, d: 3}}
      @hash2 = {a: {aa: nil, ab: 12, ac: {aca: nil}}, c: 1}
    end

    def test_deep_merge
      assert_equal({a: 1, b: {c: 2, d: 4}, e: 5}, @hash.deep_merge(b: {d: 4}, e: 5))

      tmp = @hash.clone
      tmp.deep_merge!(b: {d: 4}, e: 5, f: 10)
      assert_equal({a: 1, b: {c: 2, d: 4}, e: 5, f: 10}, tmp)
    end

    def test_key_flatten
      assert_equal({'/a' => 1, '/b/c' => 2, '/b/d' => 3}, @hash.key_flatten)

      tmp = @hash.clone
      tmp.key_flatten!
      assert_equal({'/a' => 1, '/b/c' => 2, '/b/d' => 3}, tmp)
    end

    def test_deep_compact
      assert_equal({a: {ab: 12}, c: 1}, @hash2.deep_compact)
    end

    def test_deep_compact!
      cloned = @hash2.deep_compact!
      assert_equal({a: {ab: 12}, c: 1}, cloned)
    end
  end
end
