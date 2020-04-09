require 'digest/sha2'

module Ginseng
  class Misskey
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

    def fetch_note(id)
      response = @http.get("/mulukhiya/note/#{id}")
      raise GatewayError, response.parsed_response['message'] unless response.code == 200
      return response.parsed_response
    end

    def note(body, params = {})
      body = {text: body.to_s} unless body.is_a?(Hash)
      headers = params[:headers] || {}
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      body[:i] ||= @token
      return @http.post('/api/notes/create', {body: body.to_json, headers: headers})
    end

    def favourite(id, params = {})
      headers = params[:headers] || {}
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post('/api/notes/favorites/create', {
        body: {noteId: id, i: @token}.to_json,
        headers: headers,
      })
    end

    alias fav favourite

    def upload(path, params = {})
      headers = params[:headers] || {}
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      body = {force: 'true', i: @token}
      response = @http.upload('/api/drive/files/create', path, headers, body)
      return response if params[:response] == :raw
      return JSON.parse(response.body)['id']
    end

    def upload_remote_resource(uri)
      path = File.join(
        Environment.dir,
        'tmp/media',
        Digest::SHA1.hexdigest(uri),
      )
      File.write(path, @http.get(uri))
      return upload(path)
    ensure
      File.unlink(path) if File.exist?(path)
    end

    def announcements(params = {})
      headers = params[:headers] || {}
      headers['X-Mulukhiya'] = package_class.full_name unless mulukhiya_enable?
      return @http.post('/api/announcements', {
        body: {i: @token}.to_json,
        headers: headers,
      })
    end

    def create_uri(href = '/api/notes/create')
      return @http.create_uri(href)
    end

    def self.create_tag(word)
      return '#' + word.strip.gsub(/[^[:alnum:]]+/, '_').gsub(/(^[_#]+|_$)/, '')
    end
  end
end
