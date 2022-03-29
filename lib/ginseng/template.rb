module Ginseng
  class Template
    include Package
    attr_reader :params, :path

    def initialize(name)
      @path = name if name.start_with?('/') && File.exist?(name)
      @path ||= File.join(environment_class.dir, dir, "#{name.sub(/\.erb$/, '')}.erb")
      raise RenderError, "Template file #{name} not found" unless File.exist?(@path)
      @erb = ERB.new(
        ['<%# encoding: UTF-8 -%>', File.read(@path)].join("\n"),
        **{trim_mode: '-'},
      )
      self.params = {}
    end

    def [](key)
      return @params[key]
    end

    def []=(key, value)
      @params[key] = value.is_a?(Hash) ? value.deep_symbolize_keys : value
    end

    def params=(params)
      @params = template_class.assign_values.merge(params).deep_symbolize_keys
    end

    def to_s
      return @erb.result(binding)
    end

    def self.assign_values
      return {
        package: Package,
        env: Environment,
        config: Config.instance,
      }
    end

    private

    def dir
      return 'views'
    end
  end
end
