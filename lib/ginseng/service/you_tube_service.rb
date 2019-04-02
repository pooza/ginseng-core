module Ginseng
  class YouTubeService
    include Package

    def initialize
      @config = config_class.constantize.instance
      @http = http_class.constantize.new
    end

    def lookup_video(id)
      uri = create_uri('videos')
      uri.query_values = {
        'part' => 'snippet,statistics',
        'key' => api_key,
        'id' => id,
      }
      response = @http.get(uri).to_h
      return nil unless response['items'].present?
      return response['items'].first
    rescue => e
      raise Ginseng::GatewayError, "invalid video '#{id}' (#{e.message})"
    end

    def create_uri(type)
      return Addressable::URI.parse(@config["/youtube/urls/#{type}"])
    end

    def api_key
      return @config['/google/api/key']
    end
  end
end
