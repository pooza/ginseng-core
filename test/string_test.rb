module Ginseng
  class StringTest < TestCase
    def test_ellipsize
      assert_equal('キュアソード'.ellipsize(5), 'キュアソー…')
      assert_equal('hogehogehoge'.ellipsize!(4), 'hoge…')
    end

    def test_nfkc
      assert_equal('！！！！！!!!!'.nfkc, '!!!!!!!!!')
    end

    def test_sanitize
      assert_equal('<p>なぎさ&ほのか</p>'.sanitize, 'なぎさ&ほのか ')
    end
  end
end
