dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(dir, 'lib'))
ENV['BUNDLE_GEMFILE'] = File.join(dir, 'Gemfile')

require 'ginseng'

namespace :cert do
  desc 'update cert'
  task :update do
    puts "fetch #{Ginseng::Environment.cert_file}"
    File.write(
      Ginseng::Environment.cert_file,
      Ginseng::HTTP.new.get(Ginseng::Config.instance['/cert/url']),
    )
  end

  desc 'check cert'
  task :check do
    unless Ginseng::Environment.cert_fresh?
      warn "'#{Ginseng::Environment.cert_file}' is not fresh."
      exit 1
    end
  end
end

namespace :bundle do
  desc 'update gems'
  task :update do
    sh 'bundle update'
  end

  desc 'install bundler'
  task :install_bundler do
    sh 'gem install bundler'
  end

  desc 'check gems'
  task check: [:install_bundler] do
    unless Ginseng::Environment.gem_fresh?
      warn 'gems is not fresh.'
      exit 1
    end
  end
end

desc 'test all'
task :test do
  Ginseng::TestCase.load((ARGV.first&.split(/[^[:word:],]+/) || [])[1])
end
