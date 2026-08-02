# frozen_string_literal: true

require 'webmock/test_unit'

module Ginseng
  # host_validator によるリダイレクト各ホップの検証 (mulukhiya-toot-proxy#4410)
  class HTTPHostValidatorTest < TestCase
    def setup
      @http = HTTP.new
      WebMock.disable_net_connect!
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def public_hosts(*hosts)
      return ->(host) {hosts.include?(host)}
    end

    def test_follows_redirect_when_every_hop_is_allowed
      WebMock.stub_request(:get, 'https://script.google.com/exec')
        .to_return(status: 302, headers: {'Location' => 'https://script.googleusercontent.com/echo'})
      WebMock.stub_request(:get, 'https://script.googleusercontent.com/echo')
        .to_return(status: 200, body: '{"ok":true}')

      response = @http.get(
        'https://script.google.com/exec',
        host_validator: public_hosts('script.google.com', 'script.googleusercontent.com'),
      )

      assert_equal(200, response.code)
      assert_equal('{"ok":true}', response.body)
    end

    def test_rejects_redirect_to_internal_host
      WebMock.stub_request(:get, 'https://example.com/exec')
        .to_return(status: 302, headers: {'Location' => 'http://169.254.169.254/latest/meta-data/'})

      error = assert_raise(GatewayError) do
        @http.get('https://example.com/exec', host_validator: public_hosts('example.com'))
      end

      assert_match(/Rejected host/, error.message)
      assert_not_requested(:get, 'http://169.254.169.254/latest/meta-data/')
    end

    def test_rejects_first_hop
      error = assert_raise(GatewayError) do
        @http.get('http://127.0.0.1/secret', host_validator: public_hosts('example.com'))
      end

      assert_match(/Rejected host/, error.message)
      assert_not_requested(:get, 'http://127.0.0.1/secret')
    end

    def test_resolves_relative_location
      WebMock.stub_request(:get, 'https://example.com/a').to_return(status: 302, headers: {'Location' => '/b'})
      WebMock.stub_request(:get, 'https://example.com/b').to_return(status: 200, body: 'ok')

      response = @http.get('https://example.com/a', host_validator: public_hosts('example.com'))

      assert_equal('ok', response.body)
    end

    def test_raises_on_redirect_loop
      WebMock.stub_request(:get, 'https://example.com/loop')
        .to_return(status: 302, headers: {'Location' => 'https://example.com/loop'})

      error = assert_raise(GatewayError) do
        @http.get('https://example.com/loop', host_validator: public_hosts('example.com'))
      end

      assert_match(/Too many redirects/, error.message)
    end

    # validator を渡さない既定の経路は従来どおり HTTParty に追従させる。
    def test_without_validator_keeps_httparty_behavior
      WebMock.stub_request(:get, 'https://example.com/plain').to_return(status: 200, body: 'plain')

      assert_equal('plain', @http.get('https://example.com/plain').body)
    end
  end
end
