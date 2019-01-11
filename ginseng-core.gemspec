lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ginseng'

Gem::Specification.new do |spec|
  spec.name = Ginseng::Package.name
  spec.version = Ginseng::Package.version
  spec.authors = ['Tatsuya Koishi']
  spec.email = ['tkoishi@b-shock.co.jp']
  spec.summary = 'ginseng core libraries'
  spec.description = 'ginseng core libraries'
  spec.homepage = Ginseng::Package.url
  spec.license = 'MIT'
  spec.metadata['homepage_uri'] = Ginseng::Package.url
  spec.metadata['source_code_uri'] = 'https://github.com/pooza/ginseng-core.git'
  spec.metadata['changelog_uri'] = 'https://github.com/pooza/ginseng-core/CHANGELOG.md'
  spec.require_paths = ['lib']

  spec.add_development_dependency 'activesupport'
  spec.add_development_dependency 'addressable'
  spec.add_development_dependency 'bundler', '<2.0'
  spec.add_development_dependency 'httparty'
  spec.add_development_dependency 'nokogiri'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'syslog-logger'
  spec.add_development_dependency 'test-unit'
end
