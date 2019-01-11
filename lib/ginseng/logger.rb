require 'json'
require 'syslog/logger'

module Ginseng
  class Logger < Syslog::Logger
    def initialize
      super(Package.name)
    end

    def info(message)
      super(message.to_json)
    end

    def error(message)
      super(message.to_json)
    end
  end
end
