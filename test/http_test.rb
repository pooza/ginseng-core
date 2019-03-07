require 'addressable/uri'
require 'json'

module Ginseng
  class HTTPTest < Test::Unit::TestCase
    def setup
      @http = HTTP.new
      @config = Config.instance
    end

    def test_get
      uri = Addressable::URI.parse(@config['/mastodon/url'])
      uri.path = '/about'
      r = @http.get(uri)
      assert_equal(r.code, 200)
    end

    def test_post
      uri = Addressable::URI.parse(@config['/mastodon/url'])
      uri.path = '/api/v1/statuses'
      r = @http.post(uri, {
        headers: {'Authorization' => "Bearer #{@config['/mastodon/token']}"},
        body: {status: 'ドッキドキドリームが煌めく'}.to_json,
      })
      assert_equal(r.code, 200)
    end

    def test_upload
      uri = Addressable::URI.parse(@config['/mastodon/url'])
      uri.path = '/api/v1/media'
      r = @http.upload(uri, File.join(Environment.dir, 'images/pooza.png'), {
        'Authorization' => "Bearer #{@config['/mastodon/token']}",
      })
      assert_equal(r.code, 200)
    end
  end
end
