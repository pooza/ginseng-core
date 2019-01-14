require 'active_support'
require 'active_support/core_ext'
require 'active_support/dependencies/autoload'

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym 'DSN'
  inflect.acronym 'JSON'
  inflect.acronym 'URI'
  inflect.acronym 'URL'
  inflect.acronym 'XML'
end

module Ginseng
  extend ActiveSupport::Autoload

  autoload :Config
  autoload :Environment
  autoload :Error
  autoload :Logger
  autoload :Mastodon
  autoload :Package
  autoload :Renderer
  autoload :Sinatra
  autoload :Slack
  autoload :Template

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
    autoload :XMLRenderer
  end
end
