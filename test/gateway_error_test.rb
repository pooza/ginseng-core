# frozen_string_literal: true

module Ginseng
  class GatewayErrorTest < TestCase
    def setup
      raise GatewayError, 'hoge'
    rescue => e
      @error = e
    end

    def test_create
      assert_kind_of(GatewayError, @error)
    end

    def test_status
      assert_equal(502, @error.status)
    end

    def test_source_status
      assert_equal(401, GatewayError.new('Bad response 401').source_status)
      assert_equal(503, GatewayError.new('Bad response 503').source_status)
    end

    # ⚠ ステータスを含まない message でも落ちないこと。HTTP#repeat はタイムアウトや
    # 接続失敗も GatewayError に包み直すので、この形のほうがむしろ起きやすい。
    def test_source_status_without_status
      assert_equal(502, @error.source_status)
      assert_equal(502, GatewayError.new('execution expired').source_status)
      assert_equal(502, GatewayError.new('').source_status)
    end
  end
end
