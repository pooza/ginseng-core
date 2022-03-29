module Ginseng
  class PackageTest < TestCase
    def test_name
      assert_equal('ginseng-core', Package.name)
    end

    def test_version
      assert_kind_of(String, Package.version)
    end

    def test_url
      assert_kind_of(String, Package.url)
    end

    def test_full_name
      assert_kind_of(String, Package.full_name)
    end

    def test_user_agent
      assert_kind_of(String, Package.user_agent)
    end
  end
end
