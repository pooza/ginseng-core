require 'unicode'

module Ginseng
  class Lib < Array
    include Package

    def initialize
      super
      @logger = logger_class.new
      @config = config_class.instance
      @http = http_class.new
      refresh unless exist?
      refresh if corrupted?
      load
    end

    def exist?
      return File.exist?(path)
    end

    def corrupted?
      return true unless Marshal.load(File.read(path)).is_a?(Array)
      return false
    rescue TypeError, Errno::ENOENT => e
      @logger.error(lib: self.class.to_s, path: path, message: e.message)
      return true
    end

    def underscore_name
      return self.class.to_s.split('::').last.sub(/Lib$/, '').underscore
    end

    def path
      return File.join(environment_class.dir, 'tmp/cache', "#{underscore_name}_lib")
    end

    def load
      return unless exist?
      clear
      concat(Marshal.load(File.read(path)))
    end

    def refresh
      File.write(path, Marshal.dump(fetch))
      @logger.info(lib: self.class.to_s, path: path, message: 'refreshed')
      load
    rescue => e
      @logger.error(e)
    end

    alias create refresh

    def delete
      File.unlink(path) if exist?
    end

    def fetch
      return @http.get(@config["/#{underscore_name}/url"]).parsed_response
    end

    def create_pattern(word)
      pattern = Unicode.nfkc(word.to_s).gsub(/[^[:alnum:]]/, '.? ?')
      [
        'あぁ', 'いぃ', 'うぅ', 'えぇ', 'おぉ', 'やゃ', 'ゆゅ', 'よょ',
        'アァ', 'イィ', 'ウゥ', 'エェ', 'オォ', 'ヤャ', 'ユュ', 'ヨョ'
      ].each do |v|
        pattern.gsub!(Regexp.new("[#{v}]"), "[#{v}]")
      end
      return Regexp.new(pattern)
    end
  end
end
