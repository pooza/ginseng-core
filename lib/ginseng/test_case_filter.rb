module Ginseng
  class TestCaseFilter
    include Package

    def active?
      raise ImplementError, "'#{__method__}' not implemented"
    end

    def params=(values)
      @params = values.key_flatten
    end

    def exec(cases)
      @params['/cases'].each do |pattern|
        cases.delete_if do |v|
          File.fnmatch(pattern, v)
        end
      end
    end

    def self.create(name)
      config['/test/filters'].each do |entry|
        next unless entry['name'] == name
        return "Ginseng::#{name.camelize}TestCaseFilter".constantize.new(entry)
      end
    end

    def self.all
      return enum_for(__method__) unless block_given?
      config['/test/filters'].each do |entry|
        yield TestCaseFilter.create(entry['name'])
      end
    end

    def self.config
      return Config.instance
    end

    private

    def initialize(params)
      self.params = params
    end
  end
end
