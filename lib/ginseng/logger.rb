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

      # ログ出力用にマスクした複製を返す。
      #
      # ⚠ 引数は変更しないこと。以前は arg.delete / arg[k]= で入力そのものを
      # 書き換えており、ログに渡しただけで呼び出し元の Hash から mask_fields の
      # キーが消えていた（mulukhiya で Sinatra の params が壊れた実例あり）。
      # 加えて、文字列キーの Hash では symbolize_keys した複製を回しながら元の
      # arg を delete するためマスクが効かず、シンボルキーが二重に生えたうえで
      # 素の値がログに出ていた (#478)。
      def mask(arg)
        case arg
        in Hash
          entries = arg.symbolize_keys.reject {|k, v| v.to_s.empty? || mask_field?(k)}
          return entries.transform_values {|v| mask(v)}
        in Array
          return arg.reject {|v| v.to_s.empty?}.map {|v| mask(v)}
        else
          return arg
        end
      end

      def mask_field?(key)
        return @config['/logger/mask_fields'].include?(key.to_s)
      end
    end
  end
end
