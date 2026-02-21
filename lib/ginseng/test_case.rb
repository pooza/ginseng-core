# frozen_string_literal: true

require 'test/unit'

module Ginseng
  class TestCase < Test::Unit::TestCase
    include Package

    def underscore
      return self.class.to_s.split('::').last.underscore.sub(/_test$/, '')
    end

    def disable?
      return false
    end

    def run_test
      super unless disable?
    end

    def fixture(name)
      return File.read(File.join(self.class.fixture_dir, name))
    end

    def json_fixture(name)
      return JSON.parse(fixture(name))
    end

    def self.fixture_dir
      return File.join(dir, 'fixture')
    end

    def self.load(cases = nil)
      ENV['TEST'] = Package.name
      file_map(cases).each do |name, path|
        puts "+ case: #{name}" if Environment.test?
        require path
      rescue => e
        puts "- case: #{name} (#{e.message})" if Environment.test?
      end
    end

    def self.names(cases = nil)
      return file_map(cases).keys.to_set
    end

    def self.file_map(cases = nil)
      finder = FileFinder.new
      finder.dir = dir
      finder.patterns.push('*.rb')
      all = finder.exec.to_h {|path| [File.basename(path, '.rb'), path]}
      return all unless cases
      targets = cases.split(',').map(&:underscore)
        .map {|v| [v, "#{v}_test", v.sub(/_test$/, '')]}.flatten.compact
      return all.slice(*targets)
    end

    def self.dir
      return File.join(Environment.dir, 'test')
    end
  end
end
