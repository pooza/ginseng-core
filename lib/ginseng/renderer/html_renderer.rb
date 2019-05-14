require 'erb'
require 'digest/sha1'

module Ginseng
  class HTMLRenderer < Renderer
    include Package

    def template=(name)
      @content = nil
      name.sub!(/\.html$/, '')
      @template = template_class.new("#{name}.html")
    end

    def []=(key, value)
      @content = nil
      raise RenderError, 'Template file undefined' unless @template
      @template[key] = escape(value)
    end

    def type
      return 'text/html; charset=UTF-8'
    end

    def to_s
      raise RenderError, 'Template file undefined' unless @template
      unless @content
        @content = @template.to_s
        storage = {}
        ['pre', 'textarea'].each do |element|
          pattern = Regexp.new("<#{element}.*?>.*?</\s*?#{element}.*?>", Regexp::MULTILINE)
          @template.to_s.match(pattern) do |matched|
            key = Digest::SHA1.hexdigest(matched[0])
            storage[key] = matched[0]
            @content.sub!(matched[0], key)
          end
        end
        @content.gsub!(/^\s+/, '')
        storage.map do |k, v|
          @content.sub!(k, v)
        end
      end
      return @content
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
