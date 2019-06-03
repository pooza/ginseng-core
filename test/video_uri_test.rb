module Ginseng
  class VideoURITest < Test::Unit::TestCase
    def setup
      @uri = VideoURI.parse('https://www.youtube.com/watch?v=uFfsTeExwbQ')
    end

    def test_id
      return if ENV['CI'].present?
      assert_equal(@uri.id, 'uFfsTeExwbQ')
    end

    def test_data
      return if ENV['CI'].present?
      assert(@uri.data.is_a?(Hash))
      assert(@uri.data.present?)
    end

    def test_title
      return if ENV['CI'].present?
      assert_equal(@uri.title, '【キラキラ☆プリキュアアラモード】後期エンディング 「シュビドゥビ☆スイーツタイム」 （歌：宮本佳那子）')
    end

    def test_count
      return if ENV['CI'].present?
      assert(@uri.count.is_a?(Integer))
      assert(@uri.count.present?)
    end
  end
end
