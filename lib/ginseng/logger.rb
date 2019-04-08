require 'json'
require 'syslog/logger'

module Ginseng
  class Logger < Syslog::Logger
    include Package

    def initialize
      super(package_class.constantize.name)
    end

    def info(message)
      super(create_message(message).to_json)
    end

    def error(message)
      super(create_message(message).to_json)
    end

    def create_message(src)
      return Error.create(src).to_h if src.is_a?(StandardError)
      return src
    end
  end
end
