# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # ⚠⚠ **設定の timeout が Net::HTTP まで届くこと (#514)。**
  #
  # 届いていなかった間、get / post / put / delete の実効は **Net::HTTP 既定の
  # 60 秒**で、`/http/timeout/seconds` は upload にしか効いていなかった。
  # ⚠ **HTTParty へ渡した値ではなく、ソケットに載った値を見る。**渡したつもりの
  # option が握り潰されても気付けるようにするため（実際、握り潰されてはいなかった
  # が「渡していなかった」ので同じ結果になっていた）。
  class HTTPTimeoutTest < TestCase
    # Net::HTTP#request の時点の timeout を捕まえる。WebMock は Net::HTTP を
    # 差し替えるが、HTTParty が設定した open_timeout / read_timeout は残る。
    module Probe
      def request(*args, &)
        HTTPTimeoutTest.captured.push({open: open_timeout, read: read_timeout})
        return super
      end
    end

    Net::HTTP.prepend(Probe)

    URL = 'https://example.com/t'

    class << self
      def captured
        return @captured ||= []
      end
    end

    def setup
      self.class.captured.clear
      @http = HTTP.new
      @configured = Config.instance['/http/timeout/seconds']
      WebMock.disable_net_connect!
      WebMock.stub_request(:get, URL).to_return(status: 200, body: 'x')
      WebMock.stub_request(:post, URL).to_return(status: 200, body: 'x')
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def timeouts
      return self.class.captured.last
    end

    def test_get_uses_configured_timeout
      @http.get(URL)

      assert_equal({open: @configured, read: @configured}, timeouts)
    end

    def test_post_uses_configured_timeout
      @http.post(URL, body: {a: 1})

      assert_equal({open: @configured, read: @configured}, timeouts)
    end

    # ⚠ 呼び出し側が明示した値を上書きしない。
    def test_explicit_timeout_wins
      @http.get(URL, timeout: 3)

      assert_equal({open: 3, read: 3}, timeouts)
    end

    def test_explicit_timeout_wins_with_body
      @http.post(URL, body: {a: 1}, timeout: 3)

      assert_equal({open: 3, read: 3}, timeouts)
    end

    # インスタンス単位で変えられる（retry_limit と同じ形）。
    def test_attribute_is_honored
      @http.timeout = 7

      @http.get(URL)

      assert_equal({open: 7, read: 7}, timeouts)
    end

    # host_validator の経路（ホップごとに pinning する）でも効くこと。
    def test_timeout_with_host_validator
      @http.get(URL, host_validator: ->(_host) {true})

      assert_equal({open: @configured, read: @configured}, timeouts)
    end

    # ⚠ 呼び出し側の hash を壊さない (#537)。body を伴う経路は #528 で直した
    # GET / HEAD と違い、同じ型のまま残っていた。
    def test_does_not_pollute_caller_options
      headers = {}
      options = {headers:, body: {a: 1}}

      @http.post(URL, options)

      assert_empty(headers)
      assert_equal({a: 1}, options[:body])
      assert_equal([:headers, :body], options.keys)
    end
  end
end
