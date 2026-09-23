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

    # ⚠⚠ **1 本の失敗で残りを止めない (#653・リリース前レビュー観点②)。**
    # 🔴 `RedirectGuard` が入って 3xx が例外になったので、**`http://` のまま登録された
    # hook が 1 本あるだけで、以降のアラートが 1 通も出なくなる**（実測。それまでは
    # 301 を GET に化けさせて追い、本文を落としたまま成功を返していた）。
    # ⚠ 失敗を飲まない — 全部撃ったあとで最初の例外を上げ直す。
    def self.broadcast(src)
      errors = []
      all.each do |slack|
        slack.say(src)
      rescue StandardError => e
        errors.push([slack.uri.to_s, e])
      end
      return if errors.empty?
      errors.each {|uri, e| Logger.new.error(error: e, slack: uri)}
      raise errors.first.last
    end
  end
end
