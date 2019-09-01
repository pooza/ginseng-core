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
    end

    def mulukhiya_enable?
      return @mulukhiya_enable || false
    end

    alias mulukhiya? mulukhiya_enable?

    def fetch_toot(id)
      return @http.get(create_uri("/api/v1/statuses/#{id}"))
    end

    def toot(body, params = {})
      body = {status: body.to_s} unless body.is_a?(Hash)
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post(create_uri, {body: body.to_json, headers: headers})
    end

    def upload(path, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      response = @http.upload(create_uri('/api/v1/media'), path, headers)
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
      return @http.post(create_uri("/api/v1/statuses/#{id}/favourite"), {
        body: '{}',
        headers: headers,
      })
    end

    alias fav favourite

    def reblog(id, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post(create_uri("/api/v1/statuses/#{id}/reblog"), {
        body: '{}',
        headers: headers,
      })
    end

    alias boost reblog

    def search(keyword, params = {})
      headers = params[:headers] || {}
      headers['Authorization'] ||= "Bearer #{@token}"
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      version = params[:version] || 'v2'
      params.delete(:version)
      params[:q] = keyword
      uri = create_uri("/api/#{version}/search")
      uri.query_values = params
      return @http.get(uri, {headers: headers})
    end

    def self.create_tag(word)
      return '#' + word.strip.gsub(/[^[:alnum:]]+/, '_').sub(/^_/, '').sub(/_$/, '')
    end

    def create_uri(href = '/api/v1/statuses')
      uri = @uri.clone
      uri.path = href
      return uri
    end
  end
end
