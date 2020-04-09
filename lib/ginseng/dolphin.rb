module Ginseng
  class Dolphin < Misskey
    include Package

    def initialize(uri, token = nil)
      @uri = URI.parse(uri)
      @token = token
      @mulukhiya_enable = false
      @http = http_class.new
      @http.base_uri = @uri
      @config = config_class.instance
    end

    def announcements(params = {})
      raise GatewayError, 'Dolphin does not respond to announcements.'
    end
  end
end
