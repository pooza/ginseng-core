namespace :ginseng do
  namespace :core do
    [:thin].each do |ns|
      namespace ns do
        [:start, :stop].each do |action|
          task action do
            sh "#{File.join(Ginseng::Environment.dir, 'bin', "#{ns}_daemon.rb")} #{action}"
          rescue => e
            STDERR.puts "#{e.class} #{ns}:#{action} #{e.message}"
          end
        end

        task restart: [:stop, :start]
      end
    end
  end
end
