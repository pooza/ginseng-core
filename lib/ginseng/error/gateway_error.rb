module Ginseng
  class GatewayError < Error
    def status
      return 502
    end

    def source_status
      return message.match(/ ([[:digit:]]{3})$/)[1]&.to_i || status
    end
  end
end
