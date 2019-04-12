module Ginseng
  class SlackTest < Test::Unit::TestCase
    def test_all
      Slack.all do |slack|
        assert(slack.is_a?(Slack))
      end
    end

    def test_say
      Slack.all do |slack|
        assert_equal(slack.say({text: Package.full_name}).code, 200)
      end
    end

    def test_broadcast
        assert(Slack.broadcast('ok'))
        assert_false(Slack.broadcast(NotFoundError.new('404')))
    end
  end
end
