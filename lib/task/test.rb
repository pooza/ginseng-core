desc 'test all'
task :test do
  ENV['TEST'] = Ginseng::Package.name
  require 'test/unit'
  Dir.glob(File.join(Ginseng::Environment.dir, 'test/*')).each do |t|
    require t
  end
end
