module Ginseng
  class Mailer
    attr_accessor :prefix

    def initialize
      @config = Config.instance
      @mail = ::Mail.new(charset: 'UTF-8')
      @mail['X-Mailer'] = Package.name
      @mail.from = "root@#{Environment.hostname}"
      @mail.to = @config['/mail/to']
      @mail.delivery_method(:sendmail)
      @prefix = Environment.name
    end

    def subject
      return @mail.subject
    end

    def subject=(value)
      @mail.subject = "#{prefix} #{value}" if prefix
      @mail.subject ||= vlaue
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
