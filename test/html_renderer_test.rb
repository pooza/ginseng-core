module Ginseng
  class HTMLRendererTest < Test::Unit::TestCase
    def setup
      @renderer = HTMLRenderer.new
      @renderer.template = 'test'
    end

    def test_type
      assert_equal(@renderer.type, 'text/html; charset=UTF-8')
    end

    def test_status
      assert_equal(@renderer.status, 200)
      @renderer.status = 404
      assert_equal(@renderer.status, 404)
    end

    def test_to_s
      assert_equal(@renderer.to_s.gsub(/\s/, ''), '<!doctypehtml><htmllang="ja"><body>aaa</body></html>')
    end
  end
end
