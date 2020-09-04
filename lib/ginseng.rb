require 'active_support'
require 'active_support/core_ext'
require 'zeitwerk'
require 'yaml'
require 'yajl'
require 'yajl/json_gem'
require 'ginseng/refines'

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym 'DSN'
  inflect.acronym 'HTTP'
  inflect.acronym 'URI'
  inflect.acronym 'URL'
end

module Ginseng
  using Refines

  def self.dir
    return File.expand_path('..', __dir__)
  end

  def self.loader
    config = YAML.load_file(File.join(dir, 'config/autoload.yaml'))
    loader = Zeitwerk::Loader.for_gem
    loader.inflector.inflect(config['inflections'])
    loader.setup
    return loader
  end
end

Ginseng.loader.eager_load
