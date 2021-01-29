module Ginseng
  class MailerTest < TestCase
    def setup
      @mailer = Mailer.new
      @config = Config.instance
    end

    def test_subject
      assert_nil(@mailer.subject)
      @mailer.subject = 'おめでとうございます！'
      assert_equal(@mailer.subject, '[ginseng-core] おめでとうございます！')
    end

    def test_from
      assert(@mailer.from.first.start_with?('root@'))
      prev = @mailer.from
      @mailer.from = 'pooza@b-shock.org'
      assert_equal(@mailer.from.first, 'pooza@b-shock.org')
      @mailer.from = prev
    end

    def test_to
      prev = @mailer.to
      @mailer.to = 'pooza@b-shock.org'
      assert_equal(@mailer.to.first, 'pooza@b-shock.org')
      @mailer.to = prev
    end

    def test_deliver
      @mailer.deliver('タイトル', 'ボディ')
    end
  end
end
