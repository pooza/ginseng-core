require 'addressable/uri'
require 'httparty'
require 'rest-client'
require 'digest/sha1'
require 'json'

module Ginseng
  class Mastodon
    include Package
    attr_reader :token

    def initialize(uri, token = nil)
      @uri = Addressable::URI.parse(uri)
      @token = token
    end

    def fetch_toot(id)
      return fetch(create_uri("/api/v1/statuses/#{id}"))
    end

    def toot(body)
      body = {status: body.to_s} unless body.is_a?(Hash)
      return HTTParty.post(create_uri, {
        body: body.to_json,
        headers: {
          'Content-Type' => 'application/json',
          'User-Agent' => package_class.constantize.user_agent,
          'Authorization' => "Bearer #{@token}",
          'X-Mulukhiya' => package_class.constantize.full_name,
        },
      })
    end

    def upload(path)
      response = RestClient.post(
        create_uri('/api/v1/media').to_s,
        {file: File.new(path, 'rb')},
        {
          'User-Agent' => package_class.constantize.user_agent,
          'Authorization' => "Bearer #{@token}",
        },
      )
      return JSON.parse(response.body)['id'].to_i
    end

    def self.create_tag(word)
      return '#' + word.strip.gsub(/[^[:alnum:]]+/, '_').sub(/^_/, '').sub(/_$/, '')
    end

    private

    def fetch(uri)
      return HTTParty.get(uri, {
        headers: {'User-Agent' => package_class.constantize.user_agent},
      })
    rescue => e
      raise GatewayError, "Fetch error (#{e.message})"
    end

    def create_uri(href = '/api/v1/statuses')
      uri = @uri.clone
      uri.path = href
      return uri
    end
  end
end
