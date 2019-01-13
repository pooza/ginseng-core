require 'yaml'
package = YAML.load_file(File.join(__dir__, 'config/application.yaml'))['package']

Gem::Specification.new do |spec|
  spec.name = 'ginseng-core'
  spec.version = package['version']
  spec.authors = package['authors']
  spec.email = package['email']
  spec.summary = 'ginseng core libraries'
  spec.description = 'ginseng core libraries'
  spec.homepage = package['url']
  spec.license = 'MIT'
  spec.metadata['homepage_uri'] = package['url']
  spec.require_paths = ['lib']

  spec.add_dependency 'activesupport'
  spec.add_dependency 'addressable'
  spec.add_dependency 'bundler', '<2.0'
  spec.add_dependency 'httparty'
  spec.add_dependency 'rake'
  spec.add_dependency 'rubocop'
  spec.add_dependency 'sinatra'
  spec.add_dependency 'syslog-logger'
  spec.add_dependency 'test-unit'
end
