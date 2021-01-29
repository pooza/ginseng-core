module Ginseng
  if Environment.win?
    class Logger
      def info(message); end

      def error(message); end
    end
  else
    require 'syslog/logger'
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
        if src.is_a?(Hash) && src[:error].is_a?(StandardError)
          error = Ginseng::Error.create(src[:error])
          file, line = error.backtrace.first.split(':')
          src[:error] = {
            message: error.message,
            file: file.sub("#{Environment.dir}/", ''),
            line: line.to_i,
          }
        end
        return Error.create(src).to_h if src.is_a?(StandardError)
        return src
      end
    end
  end
end
