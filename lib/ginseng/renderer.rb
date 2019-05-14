module Ginseng
  class Renderer
    include Package
    attr_accessor :status

    def initialize
      @status = 200
      @config = config_class.instance
      @logger = logger_class.new
    end

    def type
      raise ImplementError, "'#{__method__}' not implemented"
    end

    def to_s
      raise ImplementError, "'#{__method__}' not implemented"
    end
  end
end
