require 'sinatra'
require 'json'

module Ginseng
  class Sinatra < Sinatra::Base
    include Package

    def initialize
      super
      @config = config_class.constantize.instance
      @logger = logger_class.constantize.new
      @logger.info({
        message: 'starting...',
        server: {port: @config['/thin/port']},
        version: package_class.constantize.version,
      })
    end

    def before_post
      @params = JSON.parse(@body)
    rescue JSON::ParserError
      @params = params.clone
    end

    before do
      @logger.info({request: {path: request.path, params: @params}})
      @renderer = JSONRenderer.new
      @headers = request.env.select{ |k, v| k.start_with?('HTTP_')}
      @body = request.body.read.to_s
      before_post if request.request_method == 'POST'
    end

    after do
      status @renderer.status
      content_type @renderer.type
    end

    get '/about' do
      @renderer.message = package_class.constantize.full_name
      return @renderer.to_s
    end

    not_found do
      @renderer = JSONRenderer.new
      @renderer.status = 404
      @renderer.message = NotFoundError.new("Resource #{request.path} not found.").to_h
      return @renderer.to_s
    end

    error do |e|
      e = Error.create(e)
      @renderer = JSONRenderer.new
      @renderer.status = e.status
      @renderer.message = e.to_h.delete_if{ |k, v| k == :backtrace}
      @renderer.message['error'] = e.message
      Slack.broadcast(e.to_h)
      @logger.error(e.to_h)
      return @renderer.to_s
    end
  end
end