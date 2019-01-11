require 'json'

module Ginseng
  class JSONRenderer < Renderer
    attr_accessor :message

    def type
      return 'application/json; charset=UTF-8'
    end

    def to_s
      return @message.to_json
    end
  end
end
