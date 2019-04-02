module Ginseng
  class YouTubeServiceTest < Test::Unit::TestCase
    def setup
      @service = YouTubeService.new
    end

    def test_lookup_video
      video = @service.lookup_video('uFfsTeExwbQ')
      assert_true(video.is_a?(Hash))
      assert_true(video.present?)
      assert_equal(video['snippet']['title'], '【キラキラ☆プリキュアアラモード】後期エンディング 「シュビドゥビ☆スイーツタイム」 （歌：宮本佳那子）')
    end
  end
end
