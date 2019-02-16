namespace :bundle do
  def environment
    return "#{ENV['RAKE_MODULE']}::Environment".constantize
  end

  desc 'update gems'
  task :update do
    sh 'bundle update'
  end

  desc 'check gems'
  task :check do
    unless environment.gem_fresh?
      STDERR.puts 'gems is not fresh.'
      exit 1
    end
  end
end
