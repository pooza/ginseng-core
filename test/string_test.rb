# frozen_string_literal: true
module Ginseng
  class StringTest < TestCase
    def test_ellipsize
      assert_equal('キュアソー…', 'キュアソード'.ellipsize(5))
      assert_equal('hoge…', 'hogehogehoge'.ellipsize!(4))
    end

    def test_nfkc
      assert_equal('!!!!!!!!!', '！！！！！!!!!'.nfkc)
    end

    def test_sanitize
      assert_equal('なぎさ&ほのか', '<p>なぎさ&ほのか</p>'.sanitize)
      assert_equal("なぎさ\nほのか", '<p>なぎさ<br />ほのか</p>'.sanitize)
    end

    def test_bin2hex
      assert_equal('3c703ee381aae3818ee3819526e381bbe381aee3818b3c2f703e', '<p>なぎさ&ほのか</p>'.bin2hex)
    end

    def test_hex2bin
      assert_equal('<p>なぎさ&ほのか</p>', '3c703ee381aae3818ee3819526e381bbe381aee3818b3c2f703e'.hex2bin)
    end

    def test_adler32
      assert_equal('1473055422', '電柱が二本'.adler32)
    end

    def test_sha256
      assert_equal('484622047f579bba997c9a6df71f0e4c9e65c10f81d9d27cb28c5e106112d06c', '妖魔司教ザボエラ'.sha256)
    end

    def test_nokogiri
      require 'nokogiri'

      assert_kind_of(Nokogiri::HTML::Document, ''.nokogiri)
      assert_kind_of(Nokogiri::HTML::Document, '<div>hoge</div>'.nokogiri)
    end
  end
end
