module Ginseng
  class FileFinderTest < TestCase
    def setup
      @finder = FileFinder.new
      @finder.dir = File.join(Environment.dir, 'config')
    end

    def test_execute
      assert_equal(@finder.exec.count, 0)
      assert(@finder.exec.is_a?(Enumerable))

      @finder.patterns.clear
      @finder.patterns.push('*')
      assert(@finder.exec.is_a?(Enumerable))
      @finder.exec do |f|
        assert(File.exist?(f))
      end

      @finder.patterns.clear
      @finder.patterns.push('*.rb')
      assert(@finder.exec.is_a?(Enumerable))
      @finder.exec do |f|
        assert(File.exist?(f))
      end

      @finder.patterns.clear
      @finder.patterns.push('*.exe')
      assert(@finder.exec.is_a?(Enumerable))
      assert_equal(@finder.exec.count, 0)
    end
  end
end
