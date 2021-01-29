module Ginseng
  class PeriodicCreatorTest < TestCase
    def setup
      @creator = PeriodicCreator.new('weekly')
    end

    def test_destroot
      PeriodicCreator.periods.each do |period|
        assert(File.exist?(PeriodicCreator.destroot(period)))
      end
    end

    def test_create_link_name
      assert_equal(PeriodicCreator.create_link_name(900, 'sample'), '900.ginseng-core-sample')
    end
  end
end
