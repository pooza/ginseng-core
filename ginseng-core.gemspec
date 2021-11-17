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

  spec.add_dependency 'activesupport', '>=6.1.3.2' # CVE-2021-22904
  spec.add_dependency 'addressable', '>=2.8.0' # CVE-2021-32740
  spec.add_dependency 'bundler'
  spec.add_dependency 'daemon-spawn'
  spec.add_dependency 'date', ">= 3.2.1" # CVE-2021-41817
  spec.add_dependency 'erb'
  spec.add_dependency 'etc'
  spec.add_dependency 'facets'
  spec.add_dependency 'fileutils'
  spec.add_dependency 'find'
  spec.add_dependency 'httparty'
  spec.add_dependency 'json-schema'
  spec.add_dependency 'mail'
  spec.add_dependency 'multi_json'
  spec.add_dependency 'net-protocol'
  spec.add_dependency 'nokogiri', '>=1.12.5' # CVE-2021-41098
  spec.add_dependency 'optparse'
  spec.add_dependency 'rake'
  spec.add_dependency 'rest-client'
  spec.add_dependency 'sanitize'
  spec.add_dependency 'securerandom'
  spec.add_dependency 'set'
  spec.add_dependency 'time'
  spec.add_dependency 'yajl-ruby'
  spec.add_dependency 'zeitwerk', '>=2.4.0'
  spec.add_dependency 'zlib'
  spec.add_development_dependency 'pp'
  spec.add_development_dependency 'ricecream'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'rubocop-performance'
  spec.add_development_dependency 'rubocop-rake'
  spec.add_development_dependency 'test-unit'
end
