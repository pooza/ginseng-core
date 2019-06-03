module Ginseng
  class PackageTest < Test::Unit::TestCase
    def test_name
      assert_equal(Package.name, 'ginseng-core')
    end

    def test_version
      assert(Package.version.is_a?(String))
    end

    def test_url
      assert(Package.url.is_a?(String))
    end

    def test_full_name
      assert(Package.full_name.is_a?(String))
    end

    def test_user_agent
      assert(Package.user_agent.is_a?(String))
    end
  end
end
