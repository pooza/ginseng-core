require 'yaml'
package = YAML.load_file(File.join(__dir__, 'config/lib.yaml'))['package']

Gem::Specification.new do |spec|
  spec.name = 'ginseng-core'
  spec.version = package['version']
  spec.authors = package['authors']
  spec.email = package['email']
  spec.summary = package['description']
  spec.description = package['description']
  spec.homepage = package['url']
  spec.license = package['license']
  spec.metadata['homepage_uri'] = package['url']
  spec.require_paths = ['lib']

  spec.add_dependency 'activesupport'
  spec.add_dependency 'addressable'
  spec.add_dependency 'bundler'
  spec.add_dependency 'csv'
  spec.add_dependency 'daemon-spawn'
  spec.add_dependency 'httparty'
  spec.add_dependency 'rake'
  spec.add_dependency 'rest-client'
  spec.add_dependency 'syslog-logger'
  spec.add_dependency 'test-unit'
  spec.add_dependency 'unicode'
  spec.add_dependency 'yajl-ruby'
end
