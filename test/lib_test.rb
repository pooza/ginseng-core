module Ginseng
  class LibTest < Test::Unit::TestCase
    def setup
      @lib = Lib.new
    end

    def test_create_pattern
      assert_equal(@lib.create_pattern('プリキュアオールスターズNewStage2こころのともだち'), /プリキ[ユュ][アァ][オォ]ールスターズNewStage2こころのともだち/)
    end
  end
end
