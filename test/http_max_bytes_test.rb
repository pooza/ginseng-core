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

    # 🔴 **上限を付けても、応答の見え方を変えないこと (#765)。** HTTParty はブロックを
    # 渡されると `Net::HTTPResponse#body` を `Net::ReadAdapter` にしたまま返し、`to_s` は
    # そちらを読む。⚠ 実例: `File.write(path, response)` が本文ではなく
    # `#<Net::ReadAdapter…>` を書いた（pooza/ginseng-fediverse#340）。
    # ⚠ `host_validator` の経路（ホップごとに撃ち直す）も同じ。
    data('plain', {})
    data('host_validator', {host_validator: ->(_host) {true}})
    def test_to_s_returns_the_body_within_limit(options)
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 100)

      response = @http.get(URL, max_bytes: 200, **options)

      assert_equal('x' * 100, response.to_s)
      assert_equal(@http.get(URL, **options).to_s, response.to_s)
      assert_not_kind_of(Net::ReadAdapter, response.response.body)
    end

    # ⚠ 空本文では `display` も Net 側へ落ちる（`parsed_response` が nil）。
    def test_display_of_empty_body_matches_no_limit
      WebMock.stub_request(:get, URL).to_return(status: 200, body: '')
      displayed = [{}, {max_bytes: 100}].map do |options|
        StringIO.new.tap {|port| @http.get(URL, **options).display(port)}.string
      end

      assert_equal(['', ''], displayed)
    end

    # ⚠⚠ **本文の無い応答（HEAD・204・304）は、Net 側の `body` を nil のまま残す。** 無条件に
    # 戻すと `""` になり、`to_s` が上限なしと変わる。🔴 WebMock はスタブに本文を書かなくても
    # `""` を持って `ReadAdapter` にするので、HTTP を撃つ形ではこの条件を確かめられない
    # （外しても緑だった）。本物の Net::HTTP が返す形（読み終えて body が nil）を直接渡す。
    def test_restore_raw_body_keeps_nil_body
      raw = Net::HTTPNoContent.new('1.1', '204', 'No Content')
      raw.instance_variable_set(:@read, true)
      response = Struct.new(:response, :body).new(raw, '')

      @http.send(:restore_raw_body, response)

      assert_nil(raw.body)
    end

    # ⚠ **Content-Length を申告しない相手でも効くこと。**ここが事前チェックとの差。
    def test_rejects_body_over_limit
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 1000)

      error = assert_raise(TooLargeError) {@http.get(URL, max_bytes: 100)}

      assert_match(/exceeded 100 bytes/, error.message)
      # ⚠⚠ **メッセージに URL を入れない (#689)。** 🔴 メッセージはロガーの外へも運ばれ、
      # そこでは `Masking` が掛からない。
      assert_not_include(error.message, URL)
    end

    # 🔴 **URL はログの行の `url:` に残ること (#689)。** ⚠⚠ メッセージから外したので、
    # **どの URL で超えたかの手がかりはここだけ**になった。`host_validator` を渡した
    # 経路も同じ。
    def test_logs_the_url_in_its_own_field
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x' * 1000)

      [{}, {host_validator: ->(_) {true}}].each do |options|
        logged = []
        @http.instance_variable_get(:@logger).define_singleton_method(:error) {|entry| logged.push(entry)}
        assert_raise(TooLargeError) {@http.get(URL, max_bytes: 100, **options)}

        assert_equal([URL], logged.map {|entry| entry[:url]}, options.keys.inspect)
      end
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
