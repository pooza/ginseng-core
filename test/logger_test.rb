module Ginseng
  class LoggerTest < TestCase
    def setup
      @logger = Logger.new
    end

    def test_new
      assert_kind_of(Logger, @logger)
      assert_kind_of(Syslog::Logger, @logger)
    end

    def test_create_message
      assert_kind_of(Hash, @logger.create_message(StandardError.new('a')))
      assert_kind_of(Hash, @logger.create_message(Error.new('a')))
      assert_kind_of(Array, @logger.create_message([1, 2, 3]))
      assert_kind_of(Hash, @logger.create_message(a: 'a', b: 'b'))
      assert_kind_of(String, @logger.create_message('aaaaa'))
      assert_equal(@logger.create_message('string'), 'string')
      raise Ginseng::AuthError, 'unauthorized'
    rescue Ginseng::AuthError => e
      assert_equal(@logger.create_message(error: e, class: self.class.to_s), {
        error: {
          message: 'unauthorized',
          file: 'test/logger_test.rb',
          line: 19,
        },
        class: 'Ginseng::LoggerTest',
      })
    end
  end
end
