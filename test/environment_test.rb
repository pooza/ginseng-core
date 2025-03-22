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

    def test_ip_platform
      assert_kind_of(Symbol, Environment.platform)
    end

    def test_type
      assert_equal('development', Environment.type)
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
