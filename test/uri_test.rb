module Ginseng
  class URITest < TestCase
    def setup
      @cjk = URI.parse('https://whattosay.net/2018/11/27/【nhk】ネット利用だけでも契約すべきなのか？/')
      @local = URI.parse('http://localhost:3000/hoge')
    end

    def test_normalized_path
      assert_equal(@cjk.normalized_path, '/2018/11/27/%E3%80%90nhk%E3%80%91%E3%83%8D%E3%83%83%E3%83%88%E5%88%A9%E7%94%A8%E3%81%A0%E3%81%91%E3%81%A7%E3%82%82%E5%A5%91%E7%B4%84%E3%81%99%E3%81%B9%E3%81%8D%E3%81%AA%E3%81%AE%E3%81%8B%EF%BC%9F/')
    end

    def test_scan
      text = 'https://www.google.co.jp https://mstdn.b-shock.co.jp'
      URI.scan(text) do |uri|
        assert_kind_of(URI, uri)
        assert(uri.absolute?)
      end
    end

    def test_local?
      assert_false(@cjk.local?)
      assert(@local.local?)
    end

    def test_decode
      assert_equal(Ginseng::URI.decode('%E3%81%82+%E3%81%84'), 'あ い')
      assert_equal(Ginseng::URI.decode('%E3%81%82%20%E3%81%84'), 'あ い')
    end

    def test_fix
      assert_equal(URI.fix('https://www.example.com', 'https://hoge.example.com').to_s, 'https://hoge.example.com')
      assert_equal(URI.fix('https://www.example.com', '').to_s, 'https://www.example.com')
      assert_equal(URI.fix('https://www.example.com', '/').to_s, 'https://www.example.com/')
      assert_equal(URI.fix('https://www.example.com', 'fuga').to_s, 'https://www.example.com/fuga')
      assert_equal(URI.fix('https://www.example.com/hoge', 'fuga').to_s, 'https://www.example.com/hoge/fuga')
      assert_equal(URI.fix('https://www.example.com/hoge', 'fuga/fugafuga').to_s, 'https://www.example.com/hoge/fuga/fugafuga')
      assert_equal(URI.fix('https://www.example.com/hoge', '/fuga/fugafuga').to_s, 'https://www.example.com/fuga/fugafuga')
    end
  end
end
