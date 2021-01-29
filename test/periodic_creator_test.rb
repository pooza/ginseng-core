module Ginseng
  class PeriodicCreatorTest < TestCase
    def setup
      @creator = PeriodicCreator.new('monthly')
    end

    def test_create
      pp @creator
    end
  end
end
