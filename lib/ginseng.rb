require 'ginseng/refines'
require 'active_support'
require 'active_support/core_ext'
require 'zeitwerk'
require 'yaml'
require 'yajl'
require 'yajl/json_gem'

module Ginseng
  using Refines

  def self.dir
    return File.expand_path('..', __dir__)
  end

  def self.loader
    config = YAML.load_file(File.join(dir, 'config/autoload.yaml'))
    loader = Zeitwerk::Loader.new
    loader.inflector.inflect(config['inflections'])
    loader.push_dir(File.join(dir, 'lib/ginseng'), namespace: Ginseng)
    loader.collapse('lib/ginseng/*')
    return loader
  end
end

Ginseng.loader.setup
