module Ginseng
  class LoggerTest < Test::Unit::TestCase
    def setup
      @logger = Logger.new
    end

    def test_new
      assert_true(@logger.is_a?(Logger))
      assert_true(@logger.is_a?(Syslog::Logger))
    end
  end
end
