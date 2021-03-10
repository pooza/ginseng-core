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

    def test_bin2hex
      assert_equal('<p>なぎさ&ほのか</p>'.bin2hex, '3c703ee381aae3818ee3819526e381bbe381aee3818b3c2f703e')
    end

    def test_hex2bin
      assert_equal('3c703ee381aae3818ee3819526e381bbe381aee3818b3c2f703e'.hex2bin, '<p>なぎさ&ほのか</p>')
    end

    def test_adler32
      assert_equal('電柱が二本'.adler32, 1_473_055_422)
    end
  end
end
