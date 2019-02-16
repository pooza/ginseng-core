module Ginseng
  class XMLRendererTest < Test::Unit::TestCase
    def setup
      @renderer = XMLRenderer.new
      @renderer.message = 'hoge message'
    end

    def test_new
      assert(@renderer.is_a?(Renderer))
      assert(@renderer.is_a?(XMLRenderer))
    end

    def test_type
      assert_equal(@renderer.type, 'application/xml; charset=UTF-8')
    end

    def test_status
      assert_equal(@renderer.status, 200)
      @renderer.status = 404
      assert_equal(@renderer.status, 404)
    end

    def test_message
      assert_equal(@renderer.message, 'hoge message')
    end

    def test_to_s
      assert_equal(@renderer.to_s, %(<?xml version='1.0' encoding='UTF-8'?><result><message>hoge message</message></result>))
    end
  end
end
