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
      cases.delete_if do |v|
        @params['/cases'].member?(File.basename(v, '.rb'))
      end
    end

    def self.create(name)
      Config.instance['/test/filters'].each do |entry|
        next unless entry['name'] == name
        return "Ginseng::#{name.camelize}TestCaseFilter".constantize.new(entry)
      end
    end

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance['/test/filters'].each do |entry|
        yield TestCaseFilter.create(entry['name'])
      end
    end

    private

    def initialize(params)
      self.params = params
    end
  end
end
