require 'digest/sha1'

module Ginseng
  class Mastodon
    include Package
    attr_reader :uri
    attr_accessor :token
    attr_accessor :mulukhiya_enable

    def initialize(uri, token = nil)
      @uri = URI.parse(uri)
      @token = token
      @mulukhiya_enable = false
      @http = http_class.new
      @http.base_uri = @uri
      @config = config_class.instance
    end

    def mulukhiya_enable?
      return @mulukhiya_enable || false
    end

    alias mulukhiya? mulukhiya_enable?

    def fetch_toot(id)
      response = @http.get("/api/v1/statuses/#{id}")
      raise GatewayError, response['error'] if toot['error']
      return response.parsed_response
    end

    def toot(body, params = {})
      body = {status: body.to_s} unless body.is_a?(Hash)
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post('/api/v1/statuses', {body: body.to_json, headers: headers})
    end

    def upload(path, params = {})
      params[:version] ||= 1
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      response = @http.upload("/api/v#{params[:version]}/media", path, headers)
      return response if params[:response] == :raw
      return JSON.parse(response.body)['id'].to_i
    end

    def upload_remote_resource(uri)
      path = File.join(
        environment_class.dir,
        'tmp/media',
        Digest::SHA1.hexdigest(uri),
      )
      File.write(path, @http.get(uri))
      return upload(path)
    ensure
      File.unlink(path) if File.exist?(path)
    end

    def favourite(id, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post("/api/v1/statuses/#{id}/favourite", {
        body: '{}',
        headers: headers,
      })
    end

    alias fav favourite

    def reblog(id, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post("/api/v1/statuses/#{id}/reblog", {
        body: '{}',
        headers: headers,
      })
    end

    alias boost reblog

    def bookmark(id, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post("/api/v1/statuses/#{id}/bookmark", {
        body: '{}',
        headers: headers,
      })
    end

    def search(keyword, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      params[:version] ||= 2
      params[:q] = keyword
      uri = create_uri("/api/v#{params[:version]}/search")
      uri.query_values = params
      return @http.get(uri, {headers: headers})
    end

    def follow(id, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post("/api/v1/accounts/#{id}/follow", {
        body: '{}',
        headers: headers,
      })
    end

    def unfollow(id, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post("/api/v1/accounts/#{id}/unfollow", {
        body: '{}',
        headers: headers,
      })
    end

    def announcements(params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.get('/api/v1/announcements', {headers: headers})
    end

    def followers(params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      id = params[:id] || @config['/mastodon/account/id']
      uri = create_uri("/api/v1/accounts/#{id}/followers")
      uri.query_values = {limit: @config['/mastodon/followers/limit']}
      return @http.get(uri, {headers: headers})
    end

    def followees(params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      id = params[:id] || @config['/mastodon/account/id']
      uri = create_uri("/api/v1/accounts/#{id}/following")
      uri.query_values = {limit: @config['/mastodon/followees/limit']}
      return @http.get(uri, {headers: headers})
    end

    alias following followees

    def filters(params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.get('/api/v1/filters', {headers: headers})
    end

    def register_filter(params)
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post('/api/v1/filters', {
        body: {
          phrase: params[:phrase],
          context: params[:context] || [:home, :public],
        }.to_json,
        headers: headers,
      })
    end

    def unregister_filter(id, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.delete("/api/v1/filters/#{id}", {
        body: '{}',
        headers: headers,
      })
    end

    def create_uri(href = '/api/v1/statuses')
      return @http.create_uri(href)
    end

    def create_streaming_uri(stream = 'user')
      uri = self.uri.clone
      uri.scheme = 'wss'
      uri.path = '/api/v1/streaming'
      uri.query_values = {'access_token' => token, 'stream' => stream}
      return uri
    end

    def self.create_tag(word)
      return '#' + word.strip.gsub(/[^[:alnum:]]+/, '_').gsub(/(^[_#]+|_$)/, '')
    end
  end
end
