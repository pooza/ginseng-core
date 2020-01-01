dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(dir, 'lib'))
ENV['BUNDLE_GEMFILE'] ||= File.join(dir, 'Gemfile')

require 'bundler/setup'
require 'ginseng'

Dir.glob(File.join(Ginseng::Environment.dir, 'lib/task/*.rb')).sort.each do |f|
  require f
end
