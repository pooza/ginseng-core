# frozen_string_literal: true

module Ginseng
  class EnvironmentTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def test_name
      assert_equal('ginseng-core', Environment.name)
    end

    def test_hostname
      assert_kind_of(String, Environment.hostname)
    end

    def test_ip_address
      assert_kind_of(String, Environment.ip_address)
    end

    def test_platform
      assert_kind_of(Symbol, Environment.platform)
    end

    def test_type
      assert_equal(:development, Environment.type)
    end

    # rc.d が RACK_ENV=production を渡していても config だけを見て development に
    # 倒れていた（本番 Puma が development で起動する事故、cure-api #302） (#479)。
    def test_type_prefers_rack_env
      original = ENV.fetch('RACK_ENV', nil)
      ENV['RACK_ENV'] = 'production'

      assert_equal(:production, Environment.type)
      assert_true(Environment.production?)
    ensure
      ENV['RACK_ENV'] = original
    end

    def test_type_ignores_empty_rack_env
      original = ENV.fetch('RACK_ENV', nil)
      ENV['RACK_ENV'] = ''

      assert_equal(:development, Environment.type)
    ensure
      ENV['RACK_ENV'] = original
    end

    def test_development?
      assert_boolean(Environment.development?)
    end

    def test_production?
      assert_boolean(Environment.production?)
    end

    def test_test?
      assert_equal(Environment.test?, ENV['TEST'].present?)
    end

    def test_ci?
      assert_equal(Environment.ci?, ENV['CI'].present?)
    end

    def test_cron?
      assert_equal(Environment.cron?, ENV['CRON'].present?)
    end

    def test_cert_file
      assert_path_exist(Environment.cert_file)
    end

    def test_uid
      assert_predicate(Environment.uid, :positive?)
    end

    def test_gid
      assert_predicate(Environment.gid, :positive?)
    end
  end
end
