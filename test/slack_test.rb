# frozen_string_literal: true

module Ginseng
  class SlackTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def test_all
      Slack.all do |slack|
        assert_kind_of(Slack, slack)
      end
    end

    def test_create_message
      slack = Slack.all.first

      assert_equal(%({"text":"hoge"}), slack.create_body('hoge', :text))
      assert_equal(%({"text":"{\\n  \\"a\\": \\"fuga\\"\\n}"}), slack.create_body({a: 'fuga'}, :json))
      assert_equal(%({"text":"---\\n:b: fugafugafuga\\n"}), slack.create_body({b: 'fugafugafuga'}, :yaml))
      assert_equal(%({"text":"hoge"}), slack.create_body({text: 'hoge'}, :hash))
    end

    def test_post
      Slack.all do |slack|
        assert_equal(200, slack.post(text: 'post YAML').code)
        sleep(1)

        assert_equal(200, slack.post({text: 'post JSON'}, :json).code)
        sleep(1)

        assert_equal(200, slack.post('post text', :text).code)
        sleep(1)

        assert_equal(200, slack.post({text: 'post hash', attachments: [{image_url: 'https://images-na.ssl-images-amazon.com/images/I/519zZO6YAVL.jpg'}]}, :hash).code)
      end
    end

    def test_broadcast
      Slack.broadcast(message: 'OK')
    end
  end
end
