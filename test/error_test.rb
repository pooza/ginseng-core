# encoding: UTF-8

module Ginseng
  class ErrorTest < Test::Unit::TestCase
    def setup
      raise 'hoge'
    rescue => e
      @error = Error.create(e)
    end

    def test_create
      assert(@error.is_a?(Error))
    end

    def test_package
      assert_equal(@error.package, 'ginseng-core')
      @error.package = 'another_package'
      assert_equal(@error.package, 'another_package')
    end

    def test_backtrace_level
      assert(@error.backtrace_level.is_a?(Integer))
    end

    def test_status
      assert_equal(@error.status, 500)
    end

    def test_to_h
      h = @error.to_h
      assert_equal(h[:class], 'Ginseng::Error')
      assert_equal(h[:message], 'hoge')
      assert_equal(h[:source_class], 'RuntimeError')
      assert(h[:backtrace].is_a?(Array))
    end
  end
end
