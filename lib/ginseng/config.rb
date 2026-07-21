# frozen_string_literal: true

require 'singleton'
require 'json-schema'
require 'date'

module Ginseng
  class Config < Hash
    include Package
    include Singleton

    # YAML.load_file (Psych 4 = safe_load 相当) で許可するクラス。運用者が
    # config に `founded_on: 2021-03-14` のような日付を素で書いても
    # Psych::DisallowedClass で落ちないよう Date/Time/DateTime を許可する。
    PERMITTED_YAML_CLASSES = [Date, Time, DateTime].freeze

    attr_reader :raw

    def initialize
      super
      @raw = {}
      load
    end

    def load
      dirs.each do |dir|
        suffixes.each do |suffix|
          Dir.glob(File.join(dir, "*#{suffix}")).each do |f|
            key = File.basename(f, suffix)
            next if @raw.key?(key)
            @raw[key] = YAML.load_file(f, permitted_classes: PERMITTED_YAML_CLASSES)
          end
        end
      end
      basenames.reverse_each do |key|
        update(@raw[key].key_flatten) if @raw[key]
      end
    end

    alias reload load

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
      keys = Set[key]
      (raw['deprecated'] || []).each do |entry|
        next unless entry['key'] == key
        keys.merge(entry['aliases'])
        break
      end
      keys.each do |k|
        value = super(k)
        return value unless value.nil?
      end
      raise ConfigError, "'#{key}' not found"
    end

    def keys(prefix)
      return filter_map do |key, _value|
        next unless key.start_with?(prefix)
        key.sub(Regexp.new("^#{prefix}"), '').split('/')[1]
      end.sort.to_set
    end

    def local_file_path
      dirs.each do |dir|
        suffix = suffixes.find {|v| File.exist?(File.join(dir, "local#{v}"))}
        return File.join(dir, "local#{suffix}") unless suffix.nil?
      end
      return nil
    end

    def update_file(values)
      return unless path = local_file_path
      File.write(path, raw['local'].deep_merge(values.deep_stringify_keys).to_yaml)
    end

    def errors
      return JSON::Validator.fully_validate(schema, normalize_temporal(merged_raw))
    end

    # PERMITTED_YAML_CLASSES で読み込みを許した Date/Time/DateTime を、検証の
    # 直前に ISO 8601 文字列へ寄せる。JSON Schema にこれらを表す型が無いため、
    # 生のまま渡すと `type: string` の指定が必ず違反になり、ロード側で許した
    # 書き方を検証側が拒むことになる。
    #
    # キーごとに schema の type を緩める手もあるが、それでは type 検証自体を
    # 捨てることになり typo も通してしまう。かつ permitted_classes を許した
    # 以上は任意のキーが日付を受け取りうるので、ここで一括して正規化する。
    def normalize_temporal(value)
      case value
      when Hash then return value.transform_values {|v| normalize_temporal(v)}
      when Array then return value.map {|v| normalize_temporal(v)}
      when DateTime, Time, Date then return value.iso8601
      end
      return value
    end

    def merged_raw
      dest = {}
      basenames.reverse_each do |key|
        dest = Hash.deep_merge(dest, raw[key]) if raw[key]
      end
      return dest
    end

    def schema
      path = File.join(environment_class.dir, 'config/schema/base.yaml')
      @schema ||= YAML.load_file(path, permitted_classes: PERMITTED_YAML_CLASSES)
      return @schema
    end

    def pretty_print(pp)
      return pp.pp(self.class)
    end

    def self.key_flatten(prefix, node)
      return Hash.key_flatten(prefix, node)
    end

    def self.deep_merge(src, target)
      return Hash.deep_merge(src, target).with_indifferent_access
    end

    def self.load_file(name)
      name += '.yaml' if File.extname(name).empty?
      path = File.join(environment_class.dir, 'config', name)
      return YAML.load_file(path, permitted_classes: PERMITTED_YAML_CLASSES)
    end
  end
end
