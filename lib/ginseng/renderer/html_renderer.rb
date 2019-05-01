module Ginseng
  class HTMLRenderer < Renderer
    def template=(name)
      name.sub!(/\.html/i, '')
      @template = Template.new("#{name}.html")
    end

    def []=(key, value)
      raise RenderError, 'Template file undefined' unless @template
      @template[key] = value
    end

    def type
      return 'text/html; charset=UTF-8'
    end

    def to_s
      raise RenderError, 'Template file undefined' unless @template
      return @template.to_s
    end
  end
end
