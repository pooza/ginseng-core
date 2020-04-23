module Ginseng
  class Slack
    include Package
    attr_reader :uri

    def initialize(uri)
      @uri = URI.parse(uri)
      @http = http_class.new
    end

    alias url uri

    def say(message, type = :yaml)
      r = @http.post(@uri, {body: create_body(message, type)})
      raise GatewayError, "response #{r.code} (#{uri})" unless r.code == 200
      return r
    end

    def create_body(message, type = :yaml)
      case type
      when :yaml
        message = {text: YAML.dump(message)}
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
      all.map {|v| v.say(src)}
      return true
    end
  end
end
