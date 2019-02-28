require 'rack/test'

module Ginseng
  class SinatraTest < Test::Unit::TestCase
    include ::Rack::Test::Methods

    def setup
      @config = Config.instance
    end

    def app
      return Sinatra
    end

    def test_about
      header 'User-Agent', Package.user_agent
      get '/about'
      assert(last_response.ok?)
      assert_equal(%("#{Package.name} #{Package.version}"), last_response.body)
    end

    def test_not_found
      header 'User-Agent', Package.user_agent
      get '/not_found'
      assert_false(last_response.ok?)
      assert_equal(last_response.status, 404)
    end
  end
end
