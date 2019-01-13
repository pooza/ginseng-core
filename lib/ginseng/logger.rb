require 'json'
require 'syslog/logger'

module Ginseng
  class Logger < Syslog::Logger
    include Package

    def initialize
      super(package_class.constantize.name)
    end

    def info(message)
      super(message.to_json)
    end

    def error(message)
      super(message.to_json)
    end
  end
end
