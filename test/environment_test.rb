module Ginseng
  class EnvironmentTest < Test::Unit::TestCase
    def test_name
      assert_equal(Environment.name, 'ginseng-core')
    end

    def test_hostname
      assert_true(Environment.hostname.is_a?(String))
    end

    def test_ip_address
      assert_true(Environment.ip_address.is_a?(String))
    end

    def test_ip_platform
      assert_true(Environment.platform.is_a?(String))
    end

    def test_cron?
      assert_true(Environment.cron? == true || Environment.cron? == false)
    end

    def test_uid
      assert_true(Environment.uid.is_a?(Integer))
    end

    def test_gid
      assert_true(Environment.gid.is_a?(Integer))
    end
  end
end
