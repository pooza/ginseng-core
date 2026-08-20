# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # ⚠⚠ **外部への実通信をやめた (#508)。**
  #
  # ここは長く `st.mstdn.b-shock.org` を叩いており、⚠ **そのホストは既に退役して
  # いる**（名前解決できない）。CI は 3 バージョンとも赤で常態化し、その陰で
  # #507（常駐が起動しなくなる回帰）を半年以上知らせなかった。
  #
  # ⚠ **WebMock は `require` しただけでは有効にならない。** `disable_net_connect!`
  # を呼ぶまで stub の無い通信は**素通り**する。素通りに戻っても「テストは通る」
  # ので気付けないため、**遮断されていること自体を test_unstubbed_request_is_blocked
  # で固定している。**
  class HTTPTest < TestCase
    UPSTREAM = 'https://upstream.example.com'

    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      return if disable?
      WebMock.disable_net_connect!
      @http = HTTP.new
      @http.base_uri = UPSTREAM
      @image = File.join(Environment.dir, 'images/pooza.png')
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def test_head
      stub_request(:head, "#{UPSTREAM}/about").to_return(status: 200)

      assert_equal(200, @http.head('/about').code)
    end

    def test_get
      stub_request(:get, "#{UPSTREAM}/about").to_return(status: 200, body: 'about')

      r = @http.get('/about')

      assert_equal(200, r.code)
      assert_equal('about', r.body)
    end

    # ⚠ **User-Agent を必ず添えること** — 相手側で弾かれる実例があり、
    # `request` の複製 (#528 / #537) で落としやすい。
    def test_get_sends_user_agent
      stub_request(:get, "#{UPSTREAM}/about").to_return(status: 200)

      @http.get('/about')

      assert_requested(:get, "#{UPSTREAM}/about", headers: {'User-Agent' => Package.user_agent})
    end

    # Hash の body は JSON へ寄せる。⚠ 呼び出し側が Content-Type を明示したときは
    # そちらを尊重する。
    def test_post
      stub_request(:post, "#{UPSTREAM}/api/v1/statuses").to_return(status: 200, body: '{"id":"1"}')

      r = @http.post('/api/v1/statuses', {body: {status: 'ドッキドキドリームが煌めく'}})

      assert_equal(200, r.code)
      assert_requested(
        :post, "#{UPSTREAM}/api/v1/statuses",
        headers: {'Content-Type' => 'application/json'},
        body: {status: 'ドッキドキドリームが煌めく'}.to_json
      )
    end

    def test_post_keeps_explicit_content_type
      stub_request(:post, "#{UPSTREAM}/api/v1/statuses").to_return(status: 200)

      @http.post('/api/v1/statuses', {
        headers: {'Content-Type' => 'application/x-www-form-urlencoded'},
        body: {'status' => 'ドッキドキドリームが煌めく'},
      })

      assert_requested(
        :post, "#{UPSTREAM}/api/v1/statuses",
        headers: {'Content-Type' => 'application/x-www-form-urlencoded'}
      )
    end

    def test_put
      stub_request(:put, "#{UPSTREAM}/api/v1/media/1")
        .to_return(status: 200, body: '{"description":"おにぎりのレシピッピ"}')

      r = @http.put('/api/v1/media/1', {body: {description: 'おにぎりのレシピッピ'}})

      assert_equal(200, r.code)
      assert_equal('おにぎりのレシピッピ', JSON.parse(r.body)['description'])
    end

    def test_upload
      stub_request(:post, "#{UPSTREAM}/api/v1/media").to_return(status: 200, body: '{"id":"1"}')

      r = @http.upload('/api/v1/media', @image)

      assert_equal(200, r.code)
      assert_requested(:post, "#{UPSTREAM}/api/v1/media") do |request|
        request.headers['Content-Type'].start_with?('multipart/form-data')
      end
    end

    # ⚠⚠ **遮断そのものをテストする (#508)。** stub の無い通信が素通りに戻っても
    # 「テストは通る」ので、ここで固定しないと気付けない。
    # ⚠ **`repeat` に飲まれない。** `WebMock::NetConnectNotAllowedError` は
    # `StandardError` ではなく `Exception` を継承しているので、`rescue => e` に
    # 掛からず**再送もされずそのまま**上がる。⚠⚠ **ここが `GatewayError` に
    # 変わったら、遮断が retry_limit 回の実通信の試行に化けている**ということ。
    def test_unstubbed_request_is_blocked
      error = assert_raise(WebMock::NetConnectNotAllowedError) do
        @http.get('https://unstubbed.example.com/')
      end

      assert_match(/Real HTTP connections are disabled/, error.message)
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

      assert_equal(3, @http.retry_limit)
    end

    def test_timeout
      assert_kind_of(Integer, @http.timeout)
      @http.timeout = 3

      assert_equal(3, @http.timeout)
    end
  end
end
