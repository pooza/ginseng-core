module Ginseng
  class FileFinder
    attr_accessor :dir, :patterns, :mtime, :atime, :empty

    def initialize
      @patterns = []
    end

    def execute
      return enum_for(__method__) unless block_given?
      Find.find(@dir) do |f|
        next unless match_patterns?(f)
        next unless match_mtime?(f)
        next unless match_atime?(f)
        next unless match_empty?(f)
        yield f
      end
    end

    alias exec execute

    private

    def match_patterns?(path)
      return @patterns.any? do |pattern|
        File.fnmatch(pattern, File.basename(path))
      end
    end

    def match_mtime?(path)
      return true unless @mtime
      return File.new(path).mtime < @mtime.days.ago
    end

    def match_atime?(path)
      return true unless @atime
      return File.new(path).atime < @atime.days.ago
    end

    def match_empty?(path)
      return true unless @empty
      return File.size(path).zero?
    end
  end
end
