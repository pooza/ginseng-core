module Ginseng
  class SlackTest < Test::Unit::TestCase
    def test_all
      Slack.all do |slack|
        assert(slack.is_a?(Slack))
      end
    end

    def test_create_message
      slack = Slack.all.first
      assert_equal(slack.create_body('hoge', :text), %({"text":"hoge"}))
      assert_equal(slack.create_body({a: 'fuga'}, :json), %({"text":"{\\n  \\"a\\": \\"fuga\\"\\n}"}))
      assert_equal(slack.create_body({text: 'hoge'}, :hash), %({"text":"hoge"}))
    end

    def test_say
      Slack.all do |slack|
        assert_equal(slack.say({text: 'say json'}).code, 200)
        assert_equal(slack.say('say text', :text).code, 200)
        assert_equal(slack.say({text: 'say hash', attachments: [{image_url: 'https://images-na.ssl-images-amazon.com/images/I/519zZO6YAVL.jpg'}]}, :hash).code, 200)
      end
    end

    def test_broadcast
      assert(Slack.broadcast('ok'))
      assert_false(Slack.broadcast(NotFoundError.new('404')))
    end
  end
end
