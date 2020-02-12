require 'yaml'
require 'singleton'

module Ginseng
  class Config < Hash
    include Package
    include Singleton
    attr_reader :raw

    def initialize
      super
      @raw = {}
      dirs.each do |dir|
        suffixes.each do |suffix|
          Dir.glob(File.join(dir, "*#{suffix}")).each do |f|
            key = File.basename(f, suffix)
            next if @raw.member?(key)
            @raw[key] = YAML.load_file(f)
          end
        end
      end
      basenames.reverse_each do |key|
        update(Config.flatten('', @raw[key])) if @raw[key]
      end
    end

    def dirs
      return [
        File.join(environment_class.dir, 'config'),
        File.join('/usr/local/etc', package_class.name),
        File.join('/etc', package_class.name),
      ]
    end

    def suffixes
      return ['.yaml', '.yml']
    end

    def basenames
      return [
        environment_class.hostname,
        'local',
        'application',
        'lib',
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
      return Hash.deep_merge(src, target).with_indifferent_access
    end
  end
end
