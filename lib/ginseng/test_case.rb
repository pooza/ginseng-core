require 'test/unit'

module Ginseng
  class TestCase < Test::Unit::TestCase
    def self.load
      ENV['TEST'] = Package.name
      names.each do |name|
        puts "case: #{name}"
        require File.join(dir, "#{name}.rb")
      end
    end

    def self.names
      names = []
      (ARGV.first.split(/[^[:word:],]+/)[1].split(',') || []).each do |name|
        names.push(name) if File.exist?(File.join(dir, "#{name}.rb"))
        names.push("#{name}_test") if File.exist?(File.join(dir, "#{name}_test.rb"))
      end
      names ||= Dir.glob(File.join(dir, '*.rb')).map {|v| File.basename(v, '.rb')}
      TestCaseFilter.all do |filter|
        filter.exec(names) if filter.active?
      end
      return names.sort.uniq
    end

    def self.dir
      return File.join(Environment.dir, 'test')
    end
  end
end
