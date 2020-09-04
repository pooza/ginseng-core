require 'active_support'
require 'active_support/core_ext'
require 'active_support/dependencies/autoload'
require 'yaml'
require 'yajl'
require 'yajl/json_gem'
require 'ginseng/refines'

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym 'CI'
  inflect.acronym 'DSN'
  inflect.acronym 'HTTP'
  inflect.acronym 'URI'
  inflect.acronym 'URL'
end

module Ginseng
  extend ActiveSupport::Autoload
  using Refines

  autoload :CommandLine
  autoload :Config
  autoload :Crypt
  autoload :Daemon
  autoload :Environment
  autoload :Error
  autoload :HTTP
  autoload :Logger
  autoload :Package
  autoload :Slack
  autoload :Template
  autoload :TestCaseFilter
  autoload :TestCase
  autoload :URI

  autoload_under 'error' do
    autoload :AuthError
    autoload :ConfigError
    autoload :DatabaseError
    autoload :GatewayError
    autoload :ImplementError
    autoload :NotFoundError
    autoload :RenderError
    autoload :RequestError
    autoload :ValidateError
  end

  autoload_under 'test_case_filter' do
    autoload :CITestCaseFilter
  end

  def self.dir
    return File.expand_path('..', __dir__)
  end
end
