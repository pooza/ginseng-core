module Ginseng
  class YouTubeServiceTest < Test::Unit::TestCase
    def setup
      @service = YouTubeService.new
    end

    def test_lookup_video
      return if Environment.ci?
      video = @service.lookup_video('uFfsTeExwbQ')
      assert_kind_of(Hash, video)
      assert(video.present?)
      assert_equal(video['snippet']['title'], '【キラキラ☆プリキュアアラモード】後期エンディング 「シュビドゥビ☆スイーツタイム」 （歌：宮本佳那子）')
    end
  end
end
