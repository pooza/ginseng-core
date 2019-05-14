require 'sass'

module Ginseng
  class CSSRenderer < Renderer
    include Package

    def template=(name)
      path = File.join(environment_class.dir, "views/#{name}.sass")
      raise RenderError, "Template file #{name} not found" unless File.exist?(path)
      @template = Sass::Engine.new(File.read(path))
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
