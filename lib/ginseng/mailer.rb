require 'mail'

module Ginseng
  class Mailer
    include Package
    attr_accessor :prefix

    def initialize
      @config = config_class.instance
      @prefix = default_prefix
      @mail = ::Mail.new(charset: 'UTF-8')
      @mail['X-Mailer'] = name
      @mail.from = default_sender
      @mail.to = default_receipt
      @mail.delivery_method(:sendmail)
    end

    def name
      return package_class.name
    end

    def default_prefix
      return environment_class.name
    end

    def default_sender
      return "root@#{environment_class.hostname}"
    end

    def default_receipt
      return @config['/mail/to'] rescue nil
    end

    def subject
      return @mail.subject
    end

    def subject=(value)
      @mail.subject = "[#{prefix}] #{value}" if prefix
      @mail.subject ||= value
    end

    def from
      return @mail.from
    end

    def from=(value)
      @mail.from = value
    end

    def to
      return @mail.to
    end

    def to=(value)
      @mail.to = value
    end

    def body
      return @mail.body
    end

    def body=(value)
      value = value.to_yaml if value.is_a?(Hash)
      @mail.body = value
    end

    def priority
      return @mail['X-Priority']
    end

    def priority=(value)
      @mail['X-Priority'] = value
    end

    def deliver(subject = nil, body = nil)
      self.subject = subject if subject
      self.body = body if body
      @mail.deliver!
    end
  end
end
