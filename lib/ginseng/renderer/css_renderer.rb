require 'sass'

module Ginseng
  class CSSRenderer < Renderer
    def template=(name)
      @template = Sass::Engine.new(
        File.read(File.join(Environment.dir, "views/#{name}.sass")),
      )
    end

    def type
      return 'text/css; charset=UTF-8'
    end

    def to_s
      raise RenderError, 'Template file undefined' unless @template
      return @template.render
    end
  end
end
