module Ginseng
  module Package
    def environment_class
      return 'Ginseng::Environment'
    end

    def package_class
      return 'Ginseng::Package'
    end

    def config_class
      return 'Ginseng::Config'
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
