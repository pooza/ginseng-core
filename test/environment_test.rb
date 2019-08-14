module Ginseng
  class EnvironmentTest < Test::Unit::TestCase
    def test_name
      assert_equal(Environment.name, 'ginseng-core')
    end

    def test_hostname
      assert(Environment.hostname.is_a?(String))
    end

    def test_ip_address
      assert(Environment.ip_address.is_a?(String))
    end

    def test_ip_platform
      assert(Environment.platform.is_a?(String))
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

    def test_uid
      assert(Environment.uid.positive?)
    end

    def test_gid
      assert(Environment.gid.positive?)
    end
  end
end
