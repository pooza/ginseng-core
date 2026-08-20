# frozen_string_literal: true

module Ginseng
  # ⚠⚠ **SSL_CERT_FILE が存在しないパスを指さないこと (#512)。**
  #
  # 利用アプリには `cert/cacert.pem` が無い（`cert:update` を持っていなかったので
  # 一度も作られない）。それでも `HTTP#initialize` は env を立てていたため、
  # ⚠ **同じ値を `ca_file` 相当へ渡す利用者**（mulukhiya-toot-proxy の
  # `Listener#root_cert_file`）では `SSL_CTX_load_verify_file` が落ちる。
  class HTTPCertTest < TestCase
    def setup
      @original = ENV.fetch('SSL_CERT_FILE', nil)
    end

    def teardown
      if @original
        ENV['SSL_CERT_FILE'] = @original
      else
        ENV.delete('SSL_CERT_FILE')
      end
    end

    def test_does_not_point_at_missing_file
      ENV.delete('SSL_CERT_FILE')
      # ⚠ **元の実装を持っておいて戻す。** remove_method で消すと、
      # `def self.cert_file` ごと消えて後続のテストが落ちる。
      original = Environment.method(:cert_file)
      Environment.define_singleton_method(:cert_file) {'/nonexistent/cert/cacert.pem'}

      HTTP.new

      assert_nil(ENV.fetch('SSL_CERT_FILE', nil))
    ensure
      Environment.define_singleton_method(:cert_file, original)
    end

    # 在るなら従来どおり立てる。
    def test_points_at_existing_file
      ENV.delete('SSL_CERT_FILE')

      HTTP.new

      assert_equal(Environment.cert_file, ENV.fetch('SSL_CERT_FILE', nil))
      assert_path_exist(Environment.cert_file)
    end

    # ⚠ 呼び出し側が明示した値は上書きしない（従来どおり）。
    def test_keeps_explicit_value
      ENV['SSL_CERT_FILE'] = '/somewhere/else.pem'

      HTTP.new

      assert_equal('/somewhere/else.pem', ENV.fetch('SSL_CERT_FILE', nil))
    end
  end
end
