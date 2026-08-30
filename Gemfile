# frozen_string_literal: true

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
  # ⚠⚠ タグではなく SHA で固定する（pooza/ginseng-style#75）。タグは付け替えられる。
  gem 'ginseng-style', github: 'pooza/ginseng-style',
    ref: '91c49d3b512a31dcd714baf156cd253b84eb4f0f', require: false # v1.1.11
end
