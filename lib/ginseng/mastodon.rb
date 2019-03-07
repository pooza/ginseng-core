require 'addressable/uri'
require 'digest/sha1'
require 'json'

module Ginseng
  class Mastodon
    include Package
    attr_reader :token
    attr_reader :uri
    attr_accessor :mulukhiya_enable

    def initialize(uri, token = nil)
      @uri = Addressable::URI.parse(uri)
      @token = token
      @mulukhiya_enable = false
      @http = http_class.constantize.new
    end

    def mulukhiya_enable?
      return @mulukhiya_enable || false
    end

    alias mulukhiya? mulukhiya_enable?

    def fetch_toot(id)
      return @http.get(create_uri("/api/v1/statuses/#{id}"))
    end

    def toot(body)
      body = {status: body.to_s} unless body.is_a?(Hash)
      headers = {'Authorization' => "Bearer #{@token}"}
      headers['X-Mulukhiya'] = package_class.constantize.full_name unless mulukhiya_enable?
      return @http.post(create_uri, {body: body.to_json, headers: headers})
    end

    def upload(path)
      response = @http.upload(
        create_uri('/api/v1/media'),
        path,
        {'Authorization' => "Bearer #{@token}"},
      )
      return JSON.parse(response.body)['id'].to_i
    end

    def upload_remote_resource(uri)
      path = File.join(
        environment_class.constantize.dir,
        'tmp/media',
        Digest::SHA1.hexdigest(uri),
      )
      File.write(path, @http.get(uri))
      return upload(path)
    ensure
      File.unlink(path) if File.exist?(path)
    end

    def self.create_tag(word)
      return '#' + word.strip.gsub(/[^[:alnum:]]+/, '_').sub(/^_/, '').sub(/_$/, '')
    end

    private

    def create_uri(href = '/api/v1/statuses')
      uri = @uri.clone
      uri.path = href
      return uri
    end
  end
end
