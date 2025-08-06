module Ginseng
  class PeriodicCreator
    include Package

    attr_reader :dir, :counter

    def initialize(period)
      @dir = PeriodicCreator.destroot(period)
      @logger = logger_class.new
      rewind
    end

    def rewind
      @counter = 900
    end

    def clear
      Dir.glob(File.join(dir, '*')) do |f|
        next unless File.symlink?(f)
        next unless File.readlink(f).match(environment_class.dir)
        puts "delete link #{f}" if environment_class.rake?
        File.unlink(f)
        @logger.info(action: 'delete link', file: f)
      rescue => e
        @logger.error(error: e)
      end
    end

    def create!(src)
      dest = File.join(dir, create_link_name(@counter, src))
      puts "create link #{src} -> #{dest}" if environment_class.rake?
      File.symlink(src, dest)
      @logger.info(action: 'create link', src:, dest:)
      @counter += 1
    end

    def self.periods
      return [
        'weekly',
        'daily',
        'hourly',
        'frequently',
      ]
    end

    def self.destroot(period)
      raise ArgumentError, "Invalid period '#{period}'" unless periods.member?(period)
      case Environment.platform
      when :freebsd, :darwin
        return File.join('/usr/local/etc/periodic', period)
      when :debian
        return File.join('/etc', "cron.#{period}")
      else
        raise ImplementError, "'#{__method__}' not implemented on #{Environment.platform}"
      end
    end

    def self.create_link_name(counter, src)
      case Environment.platform
      when :freebsd, :darwin
        return "#{counter}.#{Environment.name}-#{File.basename(src, '.rb')}"
      when :debian
        return "#{Environment.name}-#{File.basename(src, '.rb').tr('_', '-')}"
      else
        raise ImplementError, "'#{__method__}' not implemented on #{Environment.platform}"
      end
    end
  end
end
