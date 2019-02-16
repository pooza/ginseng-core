dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(dir, 'lib'))
ENV['BUNDLE_GEMFILE'] ||= File.join(dir, 'Gemfile')
ENV['SSL_CERT_FILE'] ||= File.join(dir, 'cert/cacert.pem')
ENV['RAKE_MODULE'] = 'Ginseng'

require 'bundler/setup'
require 'ginseng'

desc 'test all'
task test: ['ginseng:core:test']

[:start, :stop, :restart].each do |action|
  desc "#{action} all"
  task action => ["thin:#{action}"]
end

Dir.glob(File.join(Ginseng::Environment.dir, 'lib/task/*.rb')).each do |f|
  require f
end
