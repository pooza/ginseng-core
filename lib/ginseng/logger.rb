# frozen_string_literal: true

module Ginseng
  if Environment.win?
    class Logger
      def info(message)
      end

      def error(message)
      end
    end
  else
    require 'syslog/logger'
    class Logger < Syslog::Logger
      include Package

      def initialize(name = nil)
        @config = config_class.instance
        name ||= package_class.name
        super
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
        case src
        in {error: error}
          file, line = error.backtrace.first.split(':')
          return mask(src.merge(error: {
            message: error.message,
            file: file.sub("#{Environment.dir}/", ''),
            line: line.to_i,
          }))
        in Hash
          return mask(src)
        in StandardError
          return src.to_h
        end
      rescue
        return src
      end

      private

      def mask(arg)
        case arg
        in Hash
          arg.symbolize_keys.reject {|_, v| v.to_s.empty?}.each do |k, v|
            if @config['/logger/mask_fields'].include?(k.to_s)
              arg.delete(k)
            else
              arg[k] = mask(v)
            end
          end
        in Array
          arg.reject {|v| v.to_s.empty?}.each_with_index do |v, i|
            arg[i] = mask(v)
          end
        else
        end
        return arg.clone
      end
    end
  end
end
