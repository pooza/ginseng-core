require 'active_support'
require 'active_support/core_ext'
require 'ginseng/monkey_patches'
require 'yajl'
require 'yajl/json_gem'
require 'zeitwerk'

module Ginseng
  def self.dir
    return File.expand_path('..', __dir__)
  end

  def self.loader
    config = YAML.load_file(File.join(dir, 'config/autoload.yaml'))
    loader = Zeitwerk::Loader.for_gem
    loader.inflector.inflect(config['inflections'])
    loader.push_dir(File.join(dir, 'lib'))
    loader.setup
  end
end

Ginseng.loader
