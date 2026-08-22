source 'https://rubygems.org'
gemspec

group :development do
  gem 'pp'
  gem 'ricecream'
          gem 'test-unit'
  gem 'timecop'
  gem 'webmock'
end

group :development, :test do
  # ⚠ rubocop 本体とプラグインはこの gem が依存として持つ。設定の正本も同じ場所。
  gem 'ginseng-style', github: 'pooza/ginseng-style', tag: 'v1.1.0', require: false
end
