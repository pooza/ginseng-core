# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  class HTTPUploadTest < TestCase
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
