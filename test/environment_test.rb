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
      assert(Environment.test?)
    end

    def test_cron?
      assert_false(Environment.cron?)
    end

    def test_uid
      assert(Environment.uid.is_a?(Integer))
    end

    def test_gid
      assert(Environment.gid.is_a?(Integer))
    end
  end
end
