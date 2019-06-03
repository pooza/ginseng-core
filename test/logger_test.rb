# encoding: UTF-8

module Ginseng
  class LoggerTest < Test::Unit::TestCase
    def setup
      @logger = Logger.new
    end

    def test_new
      assert(@logger.is_a?(Logger))
      assert(@logger.is_a?(Syslog::Logger))
    end

    def test_create_message
      assert(@logger.create_message(StandardError.new('a')).is_a?(Hash))
      assert(@logger.create_message(Error.new('a')).is_a?(Hash))
      assert(@logger.create_message([1, 2, 3]).is_a?(Array))
      assert(@logger.create_message({a: 'a', b: 'b'}).is_a?(Hash))
      assert(@logger.create_message('aaaaa').is_a?(String))
    end
  end
end
