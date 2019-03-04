require 'erb'

module Ginseng
  class Template
    include Package
    attr_reader :params

    def initialize(name)
      @path = File.join(environment_class.constantize.dir, dir, "#{name}.erb")
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

    def params=(params)
      @params = params.with_indifferent_access
    end

    def to_s
      return @erb.result(binding)
    end

    private

    def dir
      return 'views'
    end
  end
end
