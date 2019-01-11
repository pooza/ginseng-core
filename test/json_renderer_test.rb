module Ginseng
  class JSONRendererTest < Test::Unit::TestCase
    def setup
      @renderer = JSONRenderer.new
      @renderer.message = {a: 1, b: 'string', c: {d: 111, e: 333}}
    end

    def test_new
      assert_true(@renderer.is_a?(Renderer))
      assert_true(@renderer.is_a?(JSONRenderer))
    end

    def test_type
      assert_equal(@renderer.type, 'application/json; charset=UTF-8')
    end

    def test_status
      assert_equal(@renderer.status, 200)
      @renderer.status = 404
      assert_equal(@renderer.status, 404)
    end

    def test_message
      assert_equal(@renderer.message, {a: 1, b: 'string', c: {d: 111, e: 333}})
    end

    def test_to_s
      assert_equal(@renderer.to_s, '{"a":1,"b":"string","c":{"d":111,"e":333}}')
    end
  end
end
