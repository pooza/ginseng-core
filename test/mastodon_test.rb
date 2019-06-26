module Ginseng
  class MastodonTest < Test::Unit::TestCase
    def setup
      @config = Config.instance
      @mastodon = Mastodon.new(@config['/mastodon/url'], @config['/mastodon/token'])
    rescue Ginseng::ConfigError
      @mastodon = Mastodon.new(@config['/mastodon/url'])
    end

    def test_new
      assert(@mastodon.is_a?(Mastodon))
    end

    def test_uri
      assert(@mastodon.uri.is_a?(URI))
    end

    def test_mulukhiya?
      assert_false(@mastodon.mulukhiya?)
      assert_false(@mastodon.mulukhiya_enable?)
      @mastodon.mulukhiya_enable = true
      assert(@mastodon.mulukhiya?)
      assert(@mastodon.mulukhiya_enable?)
      @mastodon.mulukhiya_enable = false
    end

    def test_toot
      return if ENV['CI'].present?
      r = @mastodon.toot('文字列からトゥート')
      assert(r.is_a?(HTTParty::Response))
      assert_equal(r.response.code, '200')
      assert_equal(r.parsed_response['content'], '<p>文字列からトゥート</p>')

      r = @mastodon.toot({status: 'ハッシュからプライベートなトゥート', visibility: 'private'})
      assert(r.is_a?(HTTParty::Response))
      assert_equal(r.response.code, '200')
      assert_equal(r.parsed_response['content'], '<p>ハッシュからプライベートなトゥート</p>')
      assert_equal(r.parsed_response['visibility'], 'private')
    end

    def test_upload
      return if ENV['CI'].present?
      assert(@mastodon.upload(File.join(Environment.dir, 'images/pooza.png')).is_a?(Integer))
    end

    def test_upload_remote_resource
      return if ENV['CI'].present?
      assert(@mastodon.upload_remote_resource('https://www.b-shock.co.jp/images/ota-m.gif').is_a?(Integer))
    end

    def test_create_tag
      assert_equal(Mastodon.create_tag('宮本佳那子'), '#宮本佳那子')
      assert_equal(Mastodon.create_tag('宮本 佳那子'), '#宮本_佳那子')
      assert_equal(Mastodon.create_tag('宮本 佳那子 '), '#宮本_佳那子')
    end
  end
end
