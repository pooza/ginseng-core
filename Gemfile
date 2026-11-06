# frozen_string_literal: true

source 'https://rubygems.org'
gemspec

group :development do
  gem 'pp'
  # ⚠ この gem は依存に持たない (#739)。利用側で別の gem が引いたときと同じ状態を
  # 作り、`use_multi_json = false` を外すとテストが落ちるようにするため。
  gem 'multi_json', require: false
  gem 'ricecream'
  gem 'test-unit'
  gem 'timecop'
  gem 'webmock'
end

group :development, :test do
  # ⚠ rubocop 本体とプラグインはこの gem が依存として持つ。設定の正本も同じ場所。
  # ⚠⚠ タグではなく SHA で固定する（pooza/ginseng-style#75）。タグは付け替えられる。
  gem 'ginseng-style', github: 'pooza/ginseng-style',
    ref: '127c2854e76811eeec41e21c7bf262b4a527d2b7', require: false # v1.1.15
end
