module Ginseng
  class Package
    def self.name
      return 'ginseng-core'
    end

    def self.version
      return config_class.constantize.instance['/package/version']
    end

    def self.url
      return config_class.constantize.instance['/package/url']
    end

    def self.full_name
      return "#{name} #{version}"
    end

    def self.user_agent
      return "#{name}/#{version} (#{url})"
    end

    def self.config_class
      return 'Ginseng::Config'
    end
  end
end
