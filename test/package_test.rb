module Ginseng
  class PackageTest < Test::Unit::TestCase
    def test_name
      assert_equal(Package.name, 'ginseng-core')
    end

    def test_version
      assert_true(Package.version.is_a?(String))
    end

    def test_url
      assert_true(Package.url.is_a?(String))
    end

    def test_full_name
      assert_true(Package.full_name.is_a?(String))
    end

    def test_user_agent
      assert_true(Package.user_agent.is_a?(String))
    end
  end
end
