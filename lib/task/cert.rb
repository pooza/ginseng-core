namespace :cert do
  def path
    return File.join(Ginseng::Environment.dir, 'cert/cacert.pem')
  end

  desc 'update cert'
  task :update do
    puts "fetch #{path}"
    File.write(path, Ginseng::HTTP.new.get(Ginseng::Config.instance['/cert/url']))
  end

  desc 'check cert'
  task :check do
    unless Ginseng::Environment.cert_fresh?
      STDERR.puts "'#{path}' is not fresh."
      exit 1
    end
  end
end
