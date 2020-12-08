module Ginseng
  class HashTest < TestCase
    def setup
      @hash = {a: 1, b: {c: 2, d: 3}}
      @hash2 = {a: {aa: nil, ab: 12, ac: {aca: nil}}, c: 1}
    end

    def test_deep_merge
      assert_equal(@hash.deep_merge(b: {d: 4}, e: 5), {a: 1, b: {c: 2, d: 4}, e: 5})

      tmp = @hash.clone
      tmp.deep_merge!(b: {d: 4}, e: 5, f: 10)
      assert_equal(tmp, {a: 1, b: {c: 2, d: 4}, e: 5, f: 10})
    end

    def test_key_flatten
      assert_equal(@hash.key_flatten, {'/a' => 1, '/b/c' => 2, '/b/d' => 3})

      tmp = @hash.clone
      tmp.key_flatten!
      assert_equal(tmp, {'/a' => 1, '/b/c' => 2, '/b/d' => 3})
    end

    def test_deep_compact
      assert_equal(@hash2.deep_compact, {a: {ab: 12}, c: 1})
    end

    def test_deep_compact!
      cloned = @hash2.deep_compact!
      assert_equal(cloned, {a: {ab: 12}, c: 1})
    end
  end
end
