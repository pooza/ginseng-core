namespace :cert do
  def environment
    return "#{ENV['RAKE_MODULE']}::Environment".constantize
  end

  def config
    return "#{ENV['RAKE_MODULE']}::Config".constantize.instance
  end

  def path
    return File.join(environment.dir, 'cert/cacert.pem')
  end

  desc 'update cert'
  task :update do
    puts "fetch #{path}"
    File.write(path, HTTP.new.get(config['/cert/url']))
  end

  desc 'check cert'
  task :check do
    unless environment.cert_fresh?
      STDERR.puts "'#{path}' is not fresh."
      exit 1
    end
  end
end
