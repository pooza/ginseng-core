module Ginseng
  class TestCaseFilter
    include Package

    def name
      return params['name']
    end

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
      all do |filter|
        return filter if filter.name == name
      end
    end

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance.raw.dig('test', 'filters').each do |entry|
        yield "Ginseng::#{entry['name'].camelize}TestCaseFilter".constantize.new(entry)
      end
    end

    private

    def initialize(params)
      self.params = params
    end
  end
end
