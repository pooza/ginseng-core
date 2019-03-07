dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(dir, 'lib'))
ENV['BUNDLE_GEMFILE'] ||= File.join(dir, 'Gemfile')

require 'bundler/setup'
require 'ginseng'

desc 'test all'
task test: 'ginseng:core:test'

Dir.glob(File.join(Ginseng::Environment.dir, 'lib/task/*.rb')).each do |f|
  require f
end
