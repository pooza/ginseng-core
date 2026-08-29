# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  class HTTPUploadTest < TestCase
    # ログを捕まえるだけの double。
    #
    # ⚠⚠ **`HTTP#log` は例外を rescue して `warn` に落とす。** 受け取れなかった
    # ことが**そのまま緑に化ける**ので、どのテストでも「1 件以上あること」から
    # 確かめる。
    class LogCapture
      attr_reader :entries

      def initialize
        @entries = []
      end

      def info(message)
        @entries.push(message)
      end
    end

    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      return if disable?
      WebMock.disable_net_connect!
      @http = HTTP.new
      @http.base_uri = 'https://example.com'
      @image = File.join(Environment.dir, 'images/pooza.png')
    end

    def teardown
      WebMock.allow_net_connect!
    end

    def test_upload
      stub_request(:post, 'https://example.com/api/v1/media')
        .to_return(status: 200, body: '{"id":"12345"}', headers: {'Content-Type' => 'application/json'})

      r = @http.upload('/api/v1/media', @image, {
        headers: {'Authorization' => 'Bearer dummy'},
      })

      assert_equal(200, r.code)
      assert_equal('12345', JSON.parse(r.body)['id'])
    end

    def test_upload_with_body
      stub_request(:post, 'https://example.com/api/drive/files/create')
        .to_return(status: 200, body: '{"id":"67890"}', headers: {'Content-Type' => 'application/json'})

      r = @http.upload('/api/drive/files/create', @image, {
        body: {force: 'true', i: 'token123'},
      })

      assert_equal(200, r.code)
      assert_equal('67890', JSON.parse(r.body)['id'])
    end

    # 🟡 **`host_validator` を渡してもログの形が変わらないこと (#578)。**
    #
    # ⚠ 経路が 2 つあり、`request_validating_hops` 側は `multipart` を出して
    # いなかった。**「アップロードだったか」をログから引くと片方が漏れる。**
    # ⚠⚠ #569 で掲げた不変条件（validator を足しても結果が変わらない）の、
    # ログ側の取りこぼし。
    def test_upload_logs_multipart_through_both_paths
      stub_request(:post, 'https://example.com/api/v1/media').to_return(status: 200, body: '{}')

      shapes = [{}, {host_validator: ->(_host) {true}}].map do |extra|
        logs = LogCapture.new
        @http.instance_variable_set(:@logger, logs)

        @http.upload('/api/v1/media', @image, extra)

        assert_not_empty(logs.entries, 'ログが 1 件も出ていない')
        logs.entries.last
      end

      assert(shapes[0][:multipart], 'validator 無しの経路')
      assert(shapes[1][:multipart], 'validator ありの経路')
      assert_equal(shapes[0].keys, shapes[1].keys, '⚠ キーの並びまで揃えること（JSON の見た目が変わる）')
    end

    # ⚠⚠ **`multipart` はホップごとに変わる。** 307 / 308 以外は body を捨てて
    # GET になるので、そこで `multipart` を出すと**ログが嘘をつく**。
    def test_upload_stops_logging_multipart_after_body_dropping_redirect
      stub_request(:post, 'https://example.com/api/v1/media')
        .to_return(status: 302, headers: {'Location' => 'https://example.com/moved'})
      stub_request(:get, 'https://example.com/moved').to_return(status: 200, body: '{}')
      logs = LogCapture.new
      @http.instance_variable_set(:@logger, logs)

      @http.upload('/api/v1/media', @image, host_validator: ->(_host) {true})

      assert_equal(2, logs.entries.size, 'ホップごとに 1 件')
      assert(logs.entries.first[:multipart], '初段は multipart')
      assert_equal(:POST, logs.entries.first[:method])
      assert_not_include(logs.entries.last.keys, :multipart, '🔴 body を落としたホップで multipart を出さない')
      assert_equal(:GET, logs.entries.last[:method])
    end

    # ⚠ 307 / 308 は body ごと撃ち直すので、次のホップも multipart のまま。
    def test_upload_keeps_logging_multipart_when_body_is_replayed
      stub_request(:post, 'https://example.com/api/v1/media')
        .to_return(status: 307, headers: {'Location' => 'https://example.com/moved'})
      stub_request(:post, 'https://example.com/moved').to_return(status: 200, body: '{}')
      logs = LogCapture.new
      @http.instance_variable_set(:@logger, logs)

      @http.upload('/api/v1/media', @image, host_validator: ->(_host) {true})

      assert_equal(2, logs.entries.size)
      assert_equal([true, true], logs.entries.map {|v| v[:multipart]})
    end

    def test_upload_error
      stub_request(:post, 'https://example.com/api/v1/media')
        .to_return(status: 422, body: '{"error":"Unprocessable Entity"}')

      assert_raise(GatewayError) do
        @http.upload('/api/v1/media', @image, {
          headers: {'Authorization' => 'Bearer dummy'},
        })
      end
    end
  end
end
