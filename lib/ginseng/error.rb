module Ginseng
  class Error < StandardError
    attr_accessor :source_class
    attr_accessor :package

    def initialize(message)
      @config = Config.instance
      @package = Package.name
      super(message)
    end

    def status
      return 500
    end

    def broadcastable
      return true
    end

    def to_h
      h = {package: package, class: self.class.name, message: message}
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
