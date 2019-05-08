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
      @renderer[:mode] = 'string'
      @renderer[:content] = '<div></div>'
      assert_equal(@renderer.to_s, "<!doctype html>\n<html lang=\"ja\">\n<body>\n&lt;div&gt;&lt;/div&gt;\n</body>\n</html>\n")

      @renderer[:mode] = 'array'
      @renderer[:content] = ['aaa', '<div></div>']
      assert_equal(@renderer.to_s, "<!doctype html>\n<html lang=\"ja\">\n<body>\naaa<br>\n&lt;div&gt;&lt;/div&gt;<br>\n</body>\n</html>\n")

      @renderer[:mode] = 'hash'
      @renderer[:content] = {a: '<div></div>'}
      assert_equal(@renderer.to_s, "<!doctype html>\n<html lang=\"ja\">\n<body>\na &lt;div&gt;&lt;/div&gt;<br>\n</body>\n</html>\n")
    end
  end
end
