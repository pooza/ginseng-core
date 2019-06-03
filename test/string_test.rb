# encoding: UTF-8

module Ginseng
  class StringTest < Test::Unit::TestCase
    def test_ellipsize!
      assert_equal('キュアソード'.ellipsize(5), 'キュアソー…')
      assert_equal('hogehogehoge'.ellipsize!(4), 'hoge…')
    end
  end
end
