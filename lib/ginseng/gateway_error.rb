module Ginseng
  class GatewayError < Error
    def status
      return 502
    end
  end
end
