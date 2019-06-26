require 'active_support'
require 'active_support/core_ext'
require 'active_support/dependencies/autoload'
require 'ginseng/monkey_patches'

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym 'CSS'
  inflect.acronym 'DSN'
  inflect.acronym 'JSON'
  inflect.acronym 'HTML'
  inflect.acronym 'HTTP'
  inflect.acronym 'URI'
  inflect.acronym 'URL'
  inflect.acronym 'XML'
end

module Ginseng
  extend ActiveSupport::Autoload

  autoload :Config
  autoload :Daemon
  autoload :Environment
  autoload :Error
  autoload :HTTP
  autoload :Logger
  autoload :Mastodon
  autoload :Package
  autoload :Slack
  autoload :Template
  autoload :URI

  autoload_under 'error' do
    autoload :ConfigError
    autoload :DatabaseError
    autoload :GatewayError
    autoload :ImplementError
    autoload :NotFoundError
    autoload :RedisError
    autoload :RenderError
    autoload :RequestError
  end

  autoload_under 'service' do
    autoload :YouTubeService
  end

  autoload_under 'uri' do
    autoload :VideoURI
  end
end
