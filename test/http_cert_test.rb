# frozen_string_literal: true

module Ginseng
  # ⚠⚠ **SSL_CERT_FILE が存在しないパスを指さないこと (#512)。**
  #
  # 利用アプリには `cert/cacert.pem` が無い（`cert:update` を持っていなかったので
  # 一度も作られない）。それでも `HTTP#initialize` は env を立てていたため、
  # ⚠ **同じ値を `ca_file` 相当へ渡す利用者**（mulukhiya-toot-proxy の
  # `Listener#root_cert_file`）では `SSL_CTX_load_verify_file` が落ちる。
  class HTTPCertTest < TestCase
    # 利用アプリの Environment の代役。⚠ アプリは Ginseng::Environment を継承し、
    # dir を自分のルートへ差し替える（makoto2 の Makoto::Environment と同じ形）。
    class AppEnvironment < Environment
      def self.dir
        return '/nonexistent/app'
      end
    end

    # cert を持っているアプリの代役。
    class PresentAppEnvironment < Environment
      def self.dir
        return Ginseng::Environment.dir
      end
    end

    class AppHTTP < HTTP
      def environment_class
        return AppEnvironment
      end
    end

    class PresentAppHTTP < HTTP
      def environment_class
        return PresentAppEnvironment
      end
    end

    def setup
      @original = ENV.fetch('SSL_CERT_FILE', nil)
      @original_managed = Ginseng.managed_cert_file
    end

    def teardown
      if @original
        ENV['SSL_CERT_FILE'] = @original
      else
        ENV.delete('SSL_CERT_FILE')
      end
      Ginseng.managed_cert_file = @original_managed
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

    # ⚠⚠ **アプリの Environment を見ること (#548)。** `Ginseng::Environment` は
    # **gem のルート**を指すので、利用アプリでは「自分の `Gemfile.lock` が刺した
    # gem リビジョンに同梱された CA バンドル」を使い続けることになっていた。
    def test_uses_environment_of_the_application
      ENV.delete('SSL_CERT_FILE')

      AppHTTP.new

      assert_nil(ENV.fetch('SSL_CERT_FILE', nil), 'アプリ側に cert が無ければ立てない')
    end

    # アプリ側に在れば、そちらを立てる。
    def test_uses_application_cert_when_present
      ENV.delete('SSL_CERT_FILE')

      PresentAppHTTP.new

      assert_equal(Environment.cert_file, ENV.fetch('SSL_CERT_FILE', nil))
    end

    # ⚠⚠ **CA バンドルの取得は OS の CA ストアで検証する (#554)。**
    # これから置き換える当のバンドルで取得先を検証すると、それが古くなった時点で
    # 更新できなくなる（鶏と卵）。
    def test_with_system_cert_store_hides_env
      ENV.delete('SSL_CERT_FILE')
      HTTP.new
      installed = ENV.fetch('SSL_CERT_FILE', nil)
      seen = 'not yielded'

      Ginseng.with_system_cert_store {seen = ENV.fetch('SSL_CERT_FILE', nil)}

      assert_equal(Environment.cert_file, installed, '自分で立てた値であること')
      assert_nil(seen, 'ブロックの中では外れていること')
      assert_equal(installed, ENV.fetch('SSL_CERT_FILE', nil), '戻すこと')
    end

    # 🔴 **運用者が明示した値は外さない (#556)。** 企業内 CA やプラットフォームの
    # トラストストアを SSL_CERT_FILE で渡している環境があり、外すと TLS ごと壊れる。
    def test_with_system_cert_store_keeps_operator_value
      ENV['SSL_CERT_FILE'] = '/somewhere/corporate.pem'
      HTTP.new
      seen = nil

      Ginseng.with_system_cert_store {seen = ENV.fetch('SSL_CERT_FILE', nil)}

      assert_equal('/somewhere/corporate.pem', seen, 'ブロックの中でも残ること')
      assert_equal('/somewhere/corporate.pem', ENV.fetch('SSL_CERT_FILE', nil))
    end

    # ⚠ 例外が出ても戻すこと（戻さないと以降の通信が OS ストアに倒れる）。
    def test_with_system_cert_store_restores_on_error
      ENV.delete('SSL_CERT_FILE')
      HTTP.new
      installed = ENV.fetch('SSL_CERT_FILE', nil)

      assert_raise(RuntimeError) {Ginseng.with_system_cert_store {raise 'boom'}}

      assert_equal(installed, ENV.fetch('SSL_CERT_FILE', nil))
    end

    # 元から立っていなければ、戻したあとも立たないこと。
    def test_with_system_cert_store_keeps_unset
      ENV.delete('SSL_CERT_FILE')

      Ginseng.with_system_cert_store {nil}

      assert_nil(ENV.fetch('SSL_CERT_FILE', nil))
    end

    # ⚠ 呼び出し側が明示した値は上書きしない（従来どおり）。
    def test_keeps_explicit_value
      ENV['SSL_CERT_FILE'] = '/somewhere/else.pem'

      HTTP.new

      assert_equal('/somewhere/else.pem', ENV.fetch('SSL_CERT_FILE', nil))
    end
  end
end
