# frozen_string_literal: true

module Ginseng
  class PeriodicCreatorTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @creator = PeriodicCreator.new('weekly')
    end

    def test_destroot
      PeriodicCreator.periods.each do |period|
        assert_path_exist(PeriodicCreator.destroot(period))
      end
    end

    def test_create_link_name
      assert_equal('900.ginseng-core-sample', PeriodicCreator.create_link_name(900, 'sample'))
    end
  end
end
