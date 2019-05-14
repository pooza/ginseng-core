require 'addressable/uri'
require 'json'

module Ginseng
  class Slack
    include Package

    def initialize(url)
      @url = Addressable::URI.parse(url)
      @http = http_class.new
    end

    def say(message, type = :json)
      return @http.post(@url, {body: create_body(message, type)})
    end

    def create_body(message, type = :json)
      case type
      when :json
        message = {text: JSON.pretty_generate(message)}
      when :text
        message = {text: message}
      end
      return message.to_json
    end

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance['/slack/hooks'].each do |url|
        yield Slack.new(url)
      end
    end

    def self.broadcast(src)
      if src.is_a?(StandardError)
        e = Error.create(src)
        return false unless e.broadcastable?
        src = e.to_h
      end
      all do |slack|
        slack.say(src)
      end
      return true
    end
  end
end
