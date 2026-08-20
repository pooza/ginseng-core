# frozen_string_literal: true

module Ginseng
  class LineServiceTest < TestCase
    def disable?
      return true if environment_class.win?
      # ⚠ **`test_say` は実際に LINE へ送る (#508)。** トークンが無ければ飛ばす。
      return true unless config?('/line/token')
      return false
    end

    def setup
      # ⚠ setup は run_test（omit の判定）より先に走る。トークンが無い環境では
      # ここで ConfigError になるので、飛ばす条件を見てから作る (#508)。
      return if disable?
      @service = LineService.new
    end

    def test_say
      r = @service.say(Time.now.to_s)

      assert_kind_of(HTTParty::Response, r)
      assert_equal(200, r.code)
    end
  end
end
