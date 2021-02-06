module Ginseng
  class Slack
    include Package
    attr_reader :uri

    def initialize(uri)
      @uri = URI.parse(uri)
      @http = http_class.new
    end

    alias url uri

    def post(message, type = :yaml)
      return unless body = create_body(message, type)
      return @http.post(@uri, {body: body})
    end

    alias say post

    def create_body(message, type = :yaml)
      if message.is_a?(StandardError)
        e = Error.create(message)
        return nil unless e.broadcastable?
        message = e.to_h
      end
      message = {text: message.to_yaml} if type == :yaml
      message ||= {text: JSON.pretty_generate(message)} if type == :json
      message ||= {text: message}
      return message.to_json
    end

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance['/slack/hooks'].each do |url|
        yield Slack.new(url)
      end
    end

    def self.broadcast(src)
      all.each {|v| v.say(src)}
    end
  end
end
