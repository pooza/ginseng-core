# frozen_string_literal: true

module Ginseng
  class FileFinderTest < TestCase
    def setup
      @finder = FileFinder.new
      @finder.dir = File.join(Environment.dir, 'config')
    end

    def test_execute
      assert_equal(0, @finder.exec.count)
      assert_kind_of(Enumerable, @finder.exec)

      @finder.patterns.clear
      @finder.patterns.push('*')

      assert_kind_of(Enumerable, @finder.exec)
      @finder.exec do |f|
        assert_path_exist(f)
      end

      @finder.patterns.clear
      @finder.patterns.push('*.rb')

      assert_kind_of(Enumerable, @finder.exec)
      @finder.exec do |f|
        assert_path_exist(f)
      end

      @finder.patterns.clear
      @finder.patterns.push('*.exe')

      assert_kind_of(Enumerable, @finder.exec)
      assert_equal(0, @finder.exec.count)
    end
  end
end
