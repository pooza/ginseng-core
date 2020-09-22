require 'singleton'
require 'json-schema'

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
        update(@raw[key].key_flatten) if @raw[key]
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
      keys = [key]
      (raw['deprecated'] || []).each do |entry|
        next unless entry['key'] == key
        keys.concat(entry['aliases'])
        break
      end
      keys.each do |k|
        value = super(k)
        return value unless value.nil?
      end
      raise ConfigError, "'#{key}' not found"
    end

    def keys(prefix)
      return map do |key, value|
        next unless key.start_with?(prefix)
        key.sub(Regexp.new("^#{prefix}"), '').split('/')[1]
      end.compact.sort.uniq
    end

    def errors
      return JSON::Validator.fully_validate(schema, raw['local'])
    end

    def schema
      @schema ||= YAML.load_file(File.join(environment_class.dir, 'config/schema/base.yaml'))
      return @schema
    end

    def self.key_flatten(prefix, node)
      return Hash.key_flatten(prefix, node)
    end

    def self.deep_merge(src, target)
      return Hash.deep_merge(src, target).with_indifferent_access
    end
  end
end
