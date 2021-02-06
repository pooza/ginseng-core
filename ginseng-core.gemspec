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
  spec.required_ruby_version = '>=2.6'

  spec.add_dependency 'activesupport', '>=6.1.1'
  spec.add_dependency 'addressable'
  spec.add_dependency 'daemon-spawn'
  spec.add_dependency 'httparty'
  spec.add_dependency 'json-schema'
  spec.add_dependency 'mail'
  spec.add_dependency 'multi_json'
  spec.add_dependency 'nokogiri', '>=1.11.0.rc4' # CVE-2020-26247
  spec.add_dependency 'rake'
  spec.add_dependency 'rest-client'
  spec.add_dependency 'sanitize'
  spec.add_dependency 'unicode'
  spec.add_dependency 'yajl-ruby'
  spec.add_dependency 'zeitwerk', '>=2.4.0'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'rubocop-performance'
  spec.add_development_dependency 'test-unit'
end
