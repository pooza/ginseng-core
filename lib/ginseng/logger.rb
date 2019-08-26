require 'yajl'
require 'syslog/logger'

module Ginseng
  class Logger < Syslog::Logger
    include Package

    def initialize
      super(package_class.name)
    end

    def info(message)
      super(Yajl.dump(create_message(message)))
    end

    def error(message)
      super(Yajl.dump(create_message(message)))
    end

    def create_message(src)
      return Error.create(src).to_h if src.is_a?(StandardError)
      return src
    end
  end
end
