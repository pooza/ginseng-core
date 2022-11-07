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
      assert_equal('ginseng-core', @error.package)
      @error.package = 'another_package'

      assert_equal('another_package', @error.package)
    end

    def test_backtrace_level
      assert_predicate(@error.backtrace_level, :positive?)
    end

    def test_status
      assert_equal(500, @error.status)
    end

    def test_to_h
      h = @error.to_h

      assert_equal('Ginseng::Error', h[:class])
      assert_equal('hoge', h[:message])
      assert_equal('RuntimeError', h[:source_class])
      assert_kind_of(Array, h[:backtrace])
    end
  end
end
