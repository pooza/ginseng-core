# frozen_string_literal: true

module Ginseng
  class LineService
    include Package

    attr_reader :id, :token

    def initialize(params = {})
      @http = http_class.new
      # 🔴🔴 **資格情報を運ぶので、リダイレクトを追わせない (#653)。**
      # ⚠⚠ `http_class` のサブクラスとして足す形では届かない — **利用側は全員
      # `http_class` を自前の HTTP へ差し替えている**ので、継承経路に現れない。
      @http.guard_redirects!
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
