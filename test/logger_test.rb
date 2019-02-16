module Ginseng
  class LoggerTest < Test::Unit::TestCase
    def setup
      @logger = Logger.new
    end

    def test_new
      assert(@logger.is_a?(Logger))
      assert(@logger.is_a?(Syslog::Logger))
    end
  end
end
