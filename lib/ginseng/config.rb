require 'yaml'
require 'singleton'

module Ginseng
  class Config < Hash
    include Package
    include Singleton

    def initialize
      super
      dirs.each do |dir|
        suffixes.each do |suffix|
          Dir.glob(File.join(dir, "*#{suffix}")).each do |f|
            update(Config.flatten("/#{File.basename(f, suffix)}", YAML.load_file(f)))
          end
          basenames.each do |basename|
            f = File.join(dir, "#{basename}#{suffix}")
            update(Config.flatten('', YAML.load_file(f))) if File.exist?(f)
          end
        end
      end
    end

    def dirs
      return [
        File.join('/etc', package_class.constantize.name),
        File.join('/usr/local/etc', package_class.constantize.name),
        File.join(environment_class.constantize.dir, 'config'),
      ]
    end

    def suffixes
      return ['.yml', '.yaml']
    end

    def basenames
      return [
        'application',
        environment_class.constantize.hostname,
        'local',
      ]
    end

    def [](key)
      value = super(key)
      return value if value.present?
      raise ConfigError, "'#{key}' not found"
    end

    def self.flatten(prefix, node)
      values = {}
      if node.is_a?(Hash)
        node.each do |key, value|
          values.update(Config.flatten("#{prefix}/#{key}", value))
        end
      else
        values[prefix.downcase] = node
      end
      return values
    end
  end
end
