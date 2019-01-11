module Ginseng
  class Renderer
    attr_accessor :status

    def initialize
      @status = 200
      @config = Config.instance
      @logger = Logger.new
    end

    def type
      raise ImplementError, "'#{__method__}' not implemented"
    end

    def to_s
      raise ImplementError, "'#{__method__}' not implemented"
    end
  end
end
