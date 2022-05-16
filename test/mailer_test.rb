module Ginseng
  class MailerTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @mailer = Mailer.new
      @config = Config.instance
    end

    def test_subject
      assert_nil(@mailer.subject)
      @mailer.subject = 'おめでとうございます！'
      assert_equal('[ginseng-core] おめでとうございます！', @mailer.subject)
    end

    def test_from
      assert(@mailer.from.first.start_with?('root@'))
      prev = @mailer.from
      @mailer.from = 'pooza@b-shock.org'
      assert_equal('pooza@b-shock.org', @mailer.from.first)
      @mailer.from = prev
    end

    def test_to
      prev = @mailer.to
      @mailer.to = 'pooza@b-shock.org'
      assert_equal('pooza@b-shock.org', @mailer.to.first)
      @mailer.to = prev
    end

    def test_deliver
      @mailer.deliver('タイトル', 'ボディ')
    end
  end
end
