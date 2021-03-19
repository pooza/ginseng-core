module Ginseng
  class LineService
    include Package
    attr_reader :id, :token

    def initialize(params = {})
      @http = http_class.new
      @config = config_class.instance
      @http.base_uri = @config['/line/urls/api']
      @id = params[:id] || @config['/line/to']
      @token = params[:token] || @config['/line/token']
    end

    def say(body)
      return @http.post('/v2/bot/message/push', {
        headers: {'Authorization' => "Bearer #{token}"},
        body: {
          to: id,
          messages: [{type: 'text', text: body.to_s.strip}],
        },
      })
    end
  end
end
