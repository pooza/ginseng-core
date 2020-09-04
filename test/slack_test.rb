module Ginseng
  class SlackTest < TestCase
    def test_all
      Slack.all do |slack|
        assert_kind_of(Slack, slack)
      end
    end

    def test_create_message
      slack = Slack.all.first
      assert_equal(slack.create_body('hoge', :text), %({"text":"hoge"}))
      assert_equal(slack.create_body({a: 'fuga'}, :json), %({"text":"{\\n  \\"a\\": \\"fuga\\"\\n}"}))
      assert_equal(slack.create_body({b: 'fugafugafuga'}, :yaml), %({"text":"---\\n:b: fugafugafuga\\n"}))
      assert_equal(slack.create_body({text: 'hoge'}, :hash), %({"text":"hoge"}))
    end

    def test_post
      Slack.all do |slack|
        assert_equal(slack.post(text: 'post YAML').code, 200)
        sleep(1)
        assert_equal(slack.post({text: 'post JSON'}, :json).code, 200)
        sleep(1)
        assert_equal(slack.post('post text', :text).code, 200)
        sleep(1)
        assert_equal(slack.post({text: 'post hash', attachments: [{image_url: 'https://images-na.ssl-images-amazon.com/images/I/519zZO6YAVL.jpg'}]}, :hash).code, 200)
      end
    end

    def test_broadcast
      assert(Slack.broadcast(message: 'OK'))
      assert_false(Slack.broadcast(NotFoundError.new('404')))
    end
  end
end
