# frozen_string_literal: true
module Ginseng
  class LineServiceTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @service = LineService.new
    end

    def test_say
      r = @service.say(Time.now.to_s)

      assert_kind_of(HTTParty::Response, r)
      assert_equal(200, r.code)
    end
  end
end
