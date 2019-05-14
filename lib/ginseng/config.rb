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
        File.join('/etc', package_class.name),
        File.join('/usr/local/etc', package_class.name),
        File.join(environment_class.dir, 'config'),
      ]
    end

    def suffixes
      return ['.yml', '.yaml']
    end

    def basenames
      return [
        'application',
        'local',
        environment_class.hostname,
      ]
    end

    def [](key)
      value = super(key)
      return value unless value.nil?
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

    def self.deep_merge(src, target)
      raise ArgumentError 'Not Hash' unless target.is_a?(Hash)
      dest = (src.clone || {}).with_indifferent_access
      target.each do |k, v|
        dest[k] = v.is_a?(Hash) ? deep_merge(dest[k], v) : v
      end
      return dest.compact
    end
  end
end
