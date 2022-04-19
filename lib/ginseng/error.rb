module Ginseng
  class Error < StandardError
    include Package
    attr_accessor :source_class, :package
    attr_reader :raw_message

    def initialize(message)
      @raw_message = message
      @config = config_class.instance
      @package = package_class.name
      super
    end

    def to_h
      h = super
      h[:source_class] = @source_class if @source_class
      h[:backtrace] = backtrace[0..backtrace_level] if backtrace
      return h
    end

    def backtrace_level
      return @config['/error/backtrace/level']
    end

    def self.create(src)
      return src if src.is_a?(Error)
      dest = new(src.message)
      dest.source_class = src.class.name
      dest.set_backtrace(src.backtrace)
      return dest
    end
  end
end
