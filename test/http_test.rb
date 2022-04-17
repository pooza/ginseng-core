module Ginseng
  class HTTPTest < TestCase
    def setup
      @mastodon = HTTP.new
      @mastodon.base_uri = 'https://st.mstdn.b-shock.org/'
      @config = Config.instance
    end

    def test_head
      r = @mastodon.head('/about', {mock: {class: self.class, method: __method__}})
      assert_equal(200, r.code)
    end

    def test_get
      r = @mastodon.get('/about', {mock: {class: self.class, method: __method__}})
      assert_equal(200, r.code)
    end

    def test_post
      r = @mastodon.post('/api/v1/statuses', {
        headers: {
          'Authorization' => "Bearer #{@config['/mastodon/token']}",
          'Content-Type' => 'application/x-www-form-urlencoded',
        },
        body: {'status' => 'ドッキドキドリームが煌めく'},
        mock: {class: self.class, method: __method__},
      })
      assert_equal(200, r.code)

      r = @mastodon.post('/api/v1/statuses', {
        headers: {'Authorization' => "Bearer #{@config['/mastodon/token']}"},
        body: {status: 'ドッキドキドリームが煌めく'}.to_json,
        mock: {class: self.class, method: __method__},
      })
      assert_equal(200, r.code)
    end

    def test_put
      r = @mastodon.upload('/api/v1/media', File.join(Environment.dir, 'images/pooza.png'), {
        headers: {'Authorization' => "Bearer #{@config['/mastodon/token']}"},
      })
      id = JSON.parse(r.body)['id']
      r = @mastodon.put("/api/v1/media/#{id}", {
        body: {description: 'おにぎりのレシピッピ'},
        headers: {'Authorization' => "Bearer #{@config['/mastodon/token']}"},
        mock: {class: self.class, method: __method__},
      })
      assert_equal(200, r.code)
      assert_equal('おにぎりのレシピッピ', JSON.parse(r.body)['description'])
    end

    def test_upload
      r = @mastodon.upload('/api/v1/media', File.join(Environment.dir, 'images/pooza.png'), {
        headers: {'Authorization' => "Bearer #{@config['/mastodon/token']}"},
        mock: {class: self.class, method: __method__},
      })
      assert_equal(200, r.code)
    end

    def test_base_uri
      @mastodon.base_uri = 'https://service1.example.com'
      assert_equal(@mastodon.base_uri, Ginseng::URI.parse('https://service1.example.com'))

      @mastodon.base_uri = Ginseng::URI.parse('https://service2.example.com')
      assert_equal(@mastodon.base_uri, Ginseng::URI.parse('https://service2.example.com'))

      assert_raise RuntimeError do
        @mastodon.base_uri = '/hoge'
      end

      @mastodon.base_uri = nil
      assert_nil(@mastodon.base_uri)
    end

    def test_create_uri
      @mastodon.base_uri = nil
      assert_raise RuntimeError do
        @mastodon.create_uri('/fuga')
      end

      @mastodon.base_uri = 'https://service1.example.com'
      assert_equal(@mastodon.create_uri('/fuga'), Ginseng::URI.parse('https://service1.example.com/fuga'))
    end

    def test_retry_limit
      assert_kind_of(Integer, @mastodon.retry_limit)
      @mastodon.retry_limit = 3
      assert_equal(3, @mastodon.retry_limit)
    end
  end
end
