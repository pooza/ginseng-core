require 'ginseng/refines'
require 'active_support'
require 'active_support/core_ext'
require 'zeitwerk'
require 'yaml'
require 'yajl'
require 'yajl/json_gem'

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym 'API'
  inflect.acronym 'CI'
  inflect.acronym 'DSN'
  inflect.acronym 'HTTP'
  inflect.acronym 'MIME'
  inflect.acronym 'OAuth'
  inflect.acronym 'RSS'
  inflect.acronym 'SNS'
  inflect.acronym 'UI'
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
    loader = Zeitwerk::Loader.new
    loader.inflector.inflect(config['inflections'])
    config['entries'].each do |entry|
      loader.push_dir(File.join(dir, entry['path']), namespace: entry['namespace'].constantize)
    end
    return loader
  end

  def self.setup_debug
    require 'ricecream'
    require 'pp'
    Ricecream.disable
    return unless Environment.development?
    Ricecream.enable
    Ricecream.include_context = true
    Ricecream.colorize = true
    Ricecream.prefix = "#{Package.name} | "
    Ricecream.define_singleton_method(:arg_to_s, proc {|v| PP.pp(v)})
  end

  Bundler.require
  loader.setup
  setup_debug
end
