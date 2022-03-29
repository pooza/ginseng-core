module Ginseng
  class FileFinderTest < TestCase
    def setup
      @finder = FileFinder.new
      @finder.dir = File.join(Environment.dir, 'config')
    end

    def test_execute
      assert_equal(0, @finder.exec.count)
      assert(@finder.exec.is_a?(Enumerable))

      @finder.patterns.clear
      @finder.patterns.push('*')
      assert(@finder.exec.is_a?(Enumerable))
      @finder.exec do |f|
        assert_path_exist(f)
      end

      @finder.patterns.clear
      @finder.patterns.push('*.rb')
      assert(@finder.exec.is_a?(Enumerable))
      @finder.exec do |f|
        assert_path_exist(f)
      end

      @finder.patterns.clear
      @finder.patterns.push('*.exe')
      assert(@finder.exec.is_a?(Enumerable))
      assert_equal(0, @finder.exec.count)
    end
  end
end
