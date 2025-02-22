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
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>=3.2'

  spec.add_dependency 'activesupport', '>=7.0.7.1' # CVE-2023-38037
  spec.add_dependency 'addressable', '>=2.8.0' # CVE-2021-32740
  spec.add_dependency 'bundler', '~>2.0'
  spec.add_dependency 'cgi', '>=0.3.5' # CVE-2021-33621
  spec.add_dependency 'csv'
  spec.add_dependency 'daemon-spawn'
  spec.add_dependency 'date', '>=3.2.1' # CVE-2021-41817
  spec.add_dependency 'erb'
  spec.add_dependency 'etc'
  spec.add_dependency 'facets'
  spec.add_dependency 'fileutils', '~>1.7.0'
  spec.add_dependency 'find'
  spec.add_dependency 'httparty', '>=0.21.0' # CVE-2024-22049
  spec.add_dependency 'json-schema'
  spec.add_dependency 'mail'
  spec.add_dependency 'multi_json'
  spec.add_dependency 'net-protocol'
  spec.add_dependency 'net-smtp'
  spec.add_dependency 'nokogiri', '>=1.18.3' # CVE-2025-24928, CVE-2024-56171
  spec.add_dependency 'optparse'
  spec.add_dependency 'rake'
  spec.add_dependency 'rest-client'
  spec.add_dependency 'sanitize', '>=6.0.2' # CVE-2023-36823
  spec.add_dependency 'securerandom'
  spec.add_dependency 'set'
  spec.add_dependency 'syslog'
  spec.add_dependency 'time', '>= 0.2.2' # CVE-2023-28756
  spec.add_dependency 'yajl-ruby', '>= 1.4.3' # CVE-2022-24795
  spec.add_dependency 'zeitwerk', '>=2.4.0'
  spec.add_dependency 'zlib'
end
