namespace :ginseng do
  namespace :core do
    desc 'ginseng-core test'
    task :test do
      ENV['TEST'] = Ginseng::Package.full_name
      require 'test/unit'
      Dir.glob(File.join(Ginseng::Environment.dir, 'test/*')).each do |t|
        require t
      end
    end
  end
end
