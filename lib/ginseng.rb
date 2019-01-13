require 'active_support'
require 'active_support/core_ext'
require 'active_support/dependencies/autoload'

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym 'JSON'
  inflect.acronym 'URL'
  inflect.acronym 'URI'
  inflect.acronym 'DSN'
end

module Ginseng
  extend ActiveSupport::Autoload

  autoload :Config
  autoload :Environment
  autoload :Error
  autoload :Logger
  autoload :Package
  autoload :Renderer
  autoload :Sinatra
  autoload :Slack

  autoload_under 'error' do
    autoload :ConfigError
    autoload :DatabaseError
    autoload :GatewayError
    autoload :ImplementError
    autoload :NotFoundError
    autoload :RedisError
    autoload :RequestError
  end

  autoload_under 'renderer' do
    autoload :JSONRenderer
  end
end
