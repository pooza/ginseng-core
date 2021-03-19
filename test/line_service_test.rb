module Ginseng
  class LineServiceTest < TestCase
    def setup
      @service = LineService.new
    end

    def test_say
      r = @service.say(Time.now.to_s)
      assert_kind_of(HTTParty::Response, r)
      assert_equal(r.code, 200)
    end
  end
end
