# frozen_string_literal: true

module Ginseng
  class Slack
    include Package

    attr_reader :uri

    def initialize(uri)
      @uri = URI.parse(uri)
      @http = http_class.new
      # 🔴🔴 **資格情報を運ぶので、リダイレクトを追わせない (#653)。**
      # ⚠⚠ `http_class` のサブクラスとして足す形では届かない — **利用側は全員
      # `http_class` を自前の HTTP へ差し替えている**ので、継承経路に現れない。
      @http.guard_redirects!
    end

    alias url uri

    def post(message, type = :yaml)
      return unless body = create_body(message, type)
      return @http.post(@uri, {body:})
    end

    alias say post

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

    def self.all(&block)
      return enum_for(__method__) unless block
      Config.instance['/slack/hooks'].map {|v| Slack.new(v)}.each(&block)
    end

    def self.broadcast(src)
      all.each {|v| v.say(src)}
    end
  end
end
