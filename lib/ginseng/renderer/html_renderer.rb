require 'erb'

module Ginseng
  class HTMLRenderer < Renderer
    include Package

    def template=(name)
      name.sub!(/\.html$/, '')
      @template = template_class.constantize.new("#{name}.html")
    end

    def []=(key, value)
      raise RenderError, 'Template file undefined' unless @template
      @template[key] = escape(value)
    end

    def type
      return 'text/html; charset=UTF-8'
    end

    def to_s
      raise RenderError, 'Template file undefined' unless @template
      return @template.to_s.gsub(/^\s+/, '')
    end

    private

    def escape(value)
      if value.is_a?(Array)
        value.each_with_index do |v, i|
          value[i] = escape(v)
        end
      elsif value.is_a?(Enumerable)
        value.each do |k, v|
          value[k] = escape(v)
        end
      elsif value.is_a?(String)
        value = ERB::Util.html_escape(value)
      end
      return value
    end
  end
end
