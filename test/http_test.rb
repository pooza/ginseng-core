module Ginseng
  class HTTPTest < TestCase
    def setup
      @http = HTTP.new
      @config = Config.instance
      @config['/mastodon/url'] = 'https://st.mstdn.b-shock.org/'
    end

    def test_get
      uri = URI.parse(@config['/mastodon/url'])
      uri.path = '/about'
      r = @http.get(uri)
      assert_equal(r.code, 200)
    end

    def test_post
      return if Environment.ci?
      uri = URI.parse(@config['/mastodon/url'])
      uri.path = '/api/v1/statuses'
      r = @http.post(uri, {
        headers: {
          'Authorization' => "Bearer #{@config['/mastodon/token']}",
          'Content-Type' => 'application/x-www-form-urlencoded',
        },
        body: {'status' => 'ドッキドキドリームが煌めく'},
      })
      assert_equal(r.code, 200)

      r = @http.post(uri, {
        headers: {'Authorization' => "Bearer #{@config['/mastodon/token']}"},
        body: {status: 'ドッキドキドリームが煌めく'}.to_json,
      })
      assert_equal(r.code, 200)
    end

    def test_upload
      return if Environment.ci?
      uri = URI.parse(@config['/mastodon/url'])
      uri.path = '/api/v1/media'
      r = @http.upload(uri, File.join(Environment.dir, 'images/pooza.png'), {
        'Authorization' => "Bearer #{@config['/mastodon/token']}",
      })
      assert_equal(r.code, 200)
    end

    def test_base_uri
      @http.base_uri = 'https://service1.example.com'
      assert_equal(@http.base_uri, Ginseng::URI.parse('https://service1.example.com'))

      @http.base_uri = Ginseng::URI.parse('https://service2.example.com')
      assert_equal(@http.base_uri, Ginseng::URI.parse('https://service2.example.com'))

      assert_raise RuntimeError do
        @http.base_uri = '/hoge'
      end

      @http.base_uri = nil
      assert_nil(@http.base_uri)
    end

    def test_create_uri
      @http.base_uri = nil
      assert_raise RuntimeError do
        @http.create_uri('/fuga')
      end

      @http.base_uri = 'https://service1.example.com'
      assert_equal(@http.create_uri('/fuga'), Ginseng::URI.parse('https://service1.example.com/fuga'))
    end

    def test_retry_limit
      assert_kind_of(Integer, @http.retry_limit)
      @http.retry_limit = 3
      assert_equal(@http.retry_limit, 3)
    end
  end
end
