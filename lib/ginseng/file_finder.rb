require 'find'

module Ginseng
  class FileFinder
    attr_accessor :dir, :patterns, :mtime, :atime, :empty

    def initialize
      @patterns = []
    end

    def execute(&block)
      return enum_for(__method__) unless block
      Find.find(@dir)
        .select {|f| match_patterns?(f)}
        .select {|f| match_mtime?(f)}
        .select {|f| match_atime?(f)}
        .select {|f| match_empty?(f)}
        .each(&block)
    end

    alias exec execute

    private

    def match_patterns?(path)
      return @patterns.any? {|p| File.fnmatch(p, File.basename(path))}
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
