require 'syslog/logger'

module Ginseng
  class Logger < Syslog::Logger
    include Package

    def initialize
      super(package_class.name)
    end

    def info(message)
      super(create_message(message).to_json)
    end

    def error(message)
      super(create_message(message).to_json)
      return unless message.is_a?(StandardError)
      message.backtrace.each do |entry|
        super("  #{entry}")
      end
    end

    def create_message(src)
      return Error.create(src).to_h if src.is_a?(StandardError)
      return src
    end
  end
end
