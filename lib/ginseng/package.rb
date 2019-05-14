module Ginseng
  module Package
    def module_name
      return 'Ginseng'
    end

    def environment_class
      return "#{module_name}::Environment".constantize
    end

    def package_class
      return "#{module_name}::Package".constantize
    end

    def config_class
      return "#{module_name}::Config".constantize
    end

    def template_class
      return "#{module_name}::Template".constantize
    end

    def logger_class
      return "#{module_name}::Logger".constantize
    end

    def http_class
      return "#{module_name}::HTTP".constantize
    end

    def you_tube_service_class
      return "#{module_name}::YouTubeService".constantize
    end

    def self.name
      return 'ginseng-core'
    end

    def self.version
      return Config.instance['/package/version']
    end

    def self.url
      return Config.instance['/package/url']
    end

    def self.full_name
      return "#{name} #{version}"
    end

    def self.user_agent
      return "#{name}/#{version} (#{url})"
    end
  end
end
