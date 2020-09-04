module Ginseng
  class ErrorTest < TestCase
    def setup
      raise 'hoge'
    rescue => e
      @error = Error.create(e)
    end

    def test_create
      assert_kind_of(Error, @error)
    end

    def test_package
      assert_equal(@error.package, 'ginseng-core')
      @error.package = 'another_package'
      assert_equal(@error.package, 'another_package')
    end

    def test_backtrace_level
      assert(@error.backtrace_level.positive?)
    end

    def test_status
      assert_equal(@error.status, 500)
    end

    def test_to_h
      h = @error.to_h
      assert_equal(h[:class], 'Ginseng::Error')
      assert_equal(h[:message], 'hoge')
      assert_equal(h[:source_class], 'RuntimeError')
      assert_kind_of(Array, h[:backtrace])
    end
  end
end
