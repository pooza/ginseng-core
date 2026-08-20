# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # 受信バイト数の上限 (#526)。
  #
  # ⚠ **Content-Length を信じない。**申告が無い (chunked) 相手や過少申告する相手が
  # いるので、事前チェックだけでは上限にならない。受信しながら数えて打ち切る。
  class HTTPMaxBytesTest < TestCase
    URL = 'https://example.com/big'

    def setup
      @http = HTTP.new
      WebMock.disable_net_connect!
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def test_allows_body_within_limit
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 100)

      response = @http.get(URL, max_bytes: 200)

      assert_equal(200, response.code)
      assert_equal(100, response.body.bytesize)
    end

    # ⚠ **Content-Length を申告しない相手でも効くこと。**ここが事前チェックとの差。
    def test_rejects_body_over_limit
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 1000)

      error = assert_raise(TooLargeError) {@http.get(URL, max_bytes: 100)}

      assert_match(/exceeded 100 bytes/, error.message)
    end

    # ⚠ **再送しない。**相手が同じものを返す限り同じ場所で超えるだけで、
    # 再送のたびに上限ぶんの転送とメモリを食う。
    def test_does_not_retry_on_too_large
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 1000)

      assert_raise(TooLargeError) {@http.get(URL, max_bytes: 10)}

      assert_requested(:get, URL, times: 1)
    end

    def test_max_bytes_is_optional
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 1000)

      assert_equal(1000, @http.get(URL).body.bytesize)
    end

    # ⚠ **host_validator と併用できること。**pinning する経路 (ホップごとの
    # PinnedAddressAdapter) でも上限が効かないと、SSRF ガードのある呼び出しだけ
    # 無防備になる。
    def test_works_with_host_validator
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 1000)

      assert_raise(TooLargeError) do
        @http.get(URL, max_bytes: 100, host_validator: ->(_host) {true})
      end
    end

    def test_allows_body_within_limit_with_host_validator
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 50)

      response = @http.get(URL, max_bytes: 100, host_validator: ->(_host) {true})

      assert_equal(50, response.body.bytesize)
    end

    # ⚠⚠ **body を伴うメソッドでも効くこと (#538)。**取り出さないまま HTTParty へ
    # 渡すと**黙って捨てられ**、呼び出し側は「上限を付けた」と思い込んだまま
    # 上限なしで受け取る。get で効くものが post で効かないことは、シグネチャから
    # は分からない。
    data('post', :post)
    data('put', :put)
    data('delete', :delete)
    def test_max_bytes_works_with_body_methods(method)
      WebMock.stub_request(method, URL).to_return(status: 200, body: 'y' * 1000)

      assert_raise(TooLargeError) {@http.send(method, URL, body: {a: 1}, max_bytes: 100)}
    end

    data('post', :post)
    data('put', :put)
    data('delete', :delete)
    def test_body_methods_allow_within_limit(method)
      WebMock.stub_request(method, URL).to_return(status: 200, body: 'y' * 50)

      assert_equal(50, @http.send(method, URL, body: {a: 1}, max_bytes: 100).body.bytesize)
    end

    # ⚠ max_bytes がキーとして残って HTTParty へ流れないこと。
    def test_body_methods_keep_caller_options_intact
      WebMock.stub_request(:post, URL).to_return(status: 200, body: 'y')
      options = {body: {a: 1}, max_bytes: 100}

      @http.post(URL, options)

      assert_equal({body: {a: 1}, max_bytes: 100}, options)
    end

    # 呼び出し側の hash を壊さない (#528 と同じ約束)。
    def test_keeps_caller_options_intact
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x')
      options = {max_bytes: 100}

      @http.get(URL, options)

      assert_equal({max_bytes: 100}, options)
    end
  end
end
