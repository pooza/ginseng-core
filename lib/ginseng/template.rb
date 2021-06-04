require 'erb'

module Ginseng
  class Template
    include Package
    attr_reader :params

    def initialize(name)
      path = File.join(environment_class.dir, dir, "#{name}.erb")
      raise RenderError, "Template file #{name} not found" unless File.exist?(path)
      @erb = ERB.new(File.read(path), **{trim_mode: '-'})
      self.params = {}
    end

    def [](key)
      return @params[key]
    end

    def []=(key, value)
      value = value.deep_symbolized_keys if value.is_a?(Hash)
      @params[key] = value
    end

    def params=(params)
      @params = template_class.assign_values.perge(params).deep_symbolized_keys
    end

    def to_s
      return @erb.result(binding)
    end

    def self.assign_values
      return {
        package: package_class,
        controller: controller_class,
        sns: info_agent_service,
        env: environment_class,
        config: config,
      }
    end

    private

    def dir
      return 'views'
    end
  end
end
