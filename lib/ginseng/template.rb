require 'erb'

module Ginseng
  class Template
    def initialize(name)
      @path = File.join(Template.environment_class.constantize.dir, 'views', "#{name}.erb")
      @erb = ERB.new(File.read(@path), nil, '-')
      @params = {}.with_indifferent_access
    end

    def [](key)
      return @params[key]
    end

    def []=(key, value)
      value = value.with_indifferent_access if value.is_a?(Hash)
      @params[key] = value
    end

    def to_s
      return @erb.result(binding)
    end

    def self.environment_class
      return 'Ginseng::Environment'
    end
  end
end
