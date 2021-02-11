module Ginseng
  class EnvironmentTest < TestCase
    def test_name
      assert_equal(Environment.name, 'ginseng-core')
    end

    def test_hostname
      assert_kind_of(String, Environment.hostname)
    end

    def test_ip_address
      assert_kind_of(String, Environment.ip_address)
    end

    def test_ip_platform
      assert_kind_of(String, Environment.platform)
    end

    def test_type
      assert_equal(Environment.type, 'development')
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
      assert(File.exist?(Environment.cert_file))
    end

    def test_uid
      assert(Environment.uid.positive?)
    end

    def test_gid
      assert(Environment.gid.positive?)
    end
  end
end
