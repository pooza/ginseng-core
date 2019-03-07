require 'addressable/uri'
require 'json'

module Ginseng
  class Slack
    include Package

    def initialize(url)
      @url = Addressable::URI.parse(url)
    end

    def say(message, type = :json)
      message = JSON.pretty_generate(message) if type == :json
      return http_class.constantize.new.post(@url, {
        body: {text: message}.to_json,
      })
    end

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance['/slack/hooks'].each do |url|
        yield Slack.new(url)
      end
    end

    def self.broadcast(message)
      all do |slack|
        slack.say(message)
      end
    end
  end
end
